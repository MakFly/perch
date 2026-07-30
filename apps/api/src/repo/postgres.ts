/**
 * The board with a database behind it.
 *
 * Rows are fetched for the window and folded in `aggregate.ts`, the same module the demo
 * set uses. Ranking done twice — once in SQL, once in TypeScript — is ranking that drifts,
 * and the windows involved are small: a week of every builder, or a year of one.
 */

import { and, eq, gte, lt, lte, sql } from "drizzle-orm";
import { drizzle, type PostgresJsDatabase } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import {
  activeDays,
  dailyActivity,
  rankBuilders,
  rankGuilds,
  round2,
  splitByModel,
  streakOf,
  type DayFact,
} from "../aggregate.js";
import { builders, rateLimits, usageDays } from "../db/schema.js";
import {
  addDays,
  parseISODate,
  profileRangeStart,
  resolvePeriod,
  toISODate,
  type BoardKind,
  type Period,
  type ProfileRange,
} from "../period.js";
import type {
  BuilderPublic,
  Leaderboard,
  LeaderboardRepo,
  Profile,
  PublishDay,
  RateVerdict,
  RegisterInput,
  Registration,
} from "../types.js";

const HANDLE = /^[a-z0-9][a-z0-9_-]{1,30}$/;

export class HandleTaken extends Error {
  constructor(handle: string) {
    super(`handle "${handle}" is already taken`);
    this.name = "HandleTaken";
  }
}

export class InvalidHandle extends Error {
  constructor() {
    super("a handle is 2–31 characters of a–z, 0–9, - or _, and starts with a letter or digit");
    this.name = "InvalidHandle";
  }
}

export class PostgresRepo implements LeaderboardRepo {
  readonly mode = "postgres" as const;

  private readonly sql: postgres.Sql;
  private readonly db: PostgresJsDatabase;

  constructor(url: string) {
    // One connection is plenty for a serverless invocation, and opening ten of them per
    // cold start is how a free-tier Postgres runs out of slots.
    this.sql = postgres(url, { max: 1, prepare: false });
    this.db = drizzle(this.sql);
  }

  async register(input: RegisterInput): Promise<Registration> {
    const handle = input.handle.trim().toLowerCase();
    if (!HANDLE.test(handle)) throw new InvalidHandle();

    const token = newToken();
    const row = {
      id: crypto.randomUUID(),
      handle,
      displayName: (input.displayName ?? input.handle).trim().slice(0, 64) || handle,
      avatarUrl: input.avatarUrl ?? null,
      team: input.team?.trim().slice(0, 48) || null,
      agent: input.agent ?? "claude",
      visibility: input.visibility ?? "public",
      tokenHash: await hashToken(token),
    };

    try {
      await this.db.insert(builders).values(row);
    } catch (error) {
      if (isUniqueViolation(error)) throw new HandleTaken(handle);
      throw error;
    }
    return { handle, token };
  }

  async authenticate(token: string): Promise<string | null> {
    const digest = await hashToken(token);
    const found = await this.db
      .select({ id: builders.id })
      .from(builders)
      .where(eq(builders.tokenHash, digest))
      .limit(1);
    return found[0]?.id ?? null;
  }

  /**
   * One upsert, which is the whole limiter: the counter is incremented and read back in a
   * single statement, so two invocations landing at once cannot both read "0 so far".
   *
   * It fails **open**. The window between deploying this and running the migration is a
   * window where the table does not exist, and a limiter that answers 500 when its own
   * storage is missing takes the API down in order to protect it. The failure is logged
   * rather than swallowed, because "the limiter is off" is not something to discover from
   * the bill.
   */
  async take(bucket: string, limit: number, windowSeconds: number): Promise<RateVerdict> {
    const now = Date.now();
    const window = Math.max(1, Math.floor(windowSeconds)) * 1000;
    const startedAt = Math.floor(now / window) * window;
    const windowStart = new Date(startedAt);
    const retryAfter = Math.max(1, Math.ceil((startedAt + window - now) / 1000));

    try {
      const [row] = await this.db
        .insert(rateLimits)
        .values({ bucket, windowStart, hits: 1 })
        .onConflictDoUpdate({
          target: [rateLimits.bucket, rateLimits.windowStart],
          set: { hits: sql`${rateLimits.hits} + 1` },
        })
        .returning({ hits: rateLimits.hits });

      // A bucket's earlier windows are dead the moment a new one opens, and deleting them
      // here is what keeps the table proportional to what is active.
      await this.db
        .delete(rateLimits)
        .where(and(eq(rateLimits.bucket, bucket), lt(rateLimits.windowStart, windowStart)));

      return { allowed: (row?.hits ?? 1) <= limit, retryAfter };
    } catch (error) {
      console.error("rate limit unavailable — allowing the request", error);
      return { allowed: true, retryAfter: 0 };
    }
  }

  async publish(builderId: string, days: PublishDay[]): Promise<number> {
    if (days.length === 0) return 0;

    const values = days.map((day) => ({
      builderId,
      day: day.day,
      model: day.model.slice(0, 64),
      inputTokens: day.inputTokens,
      outputTokens: day.outputTokens,
      cacheReadTokens: day.cacheReadTokens,
      cacheWriteTokens: day.cacheWriteTokens,
      costUsd: day.costUsd,
      focusSeconds: day.focusSeconds,
      sessions: day.sessions,
    }));

    // A publish is authoritative for the window it covers.
    //
    // Upserting alone is not enough, and this was found the expensive way: the client
    // started sending `Opus 5` where it used to send `claude-opus-5`, the primary key
    // includes the model, so nothing was overwritten — the old rows stayed and every
    // total doubled overnight. The same happens whenever a model stops being used, or a
    // day loses rows after a re-index.
    //
    // So: delete what this builder has inside the payload's own day range, then insert.
    // Bounded by the payload rather than by a fixed window, so a publish of the last 45
    // days can never touch day 200.
    const from = values.reduce((min, row) => (row.day < min ? row.day : min), values[0]!.day);
    const to = values.reduce((max, row) => (row.day > max ? row.day : max), values[0]!.day);

    await this.db.transaction(async (tx) => {
      await tx
        .delete(usageDays)
        .where(
          and(
            eq(usageDays.builderId, builderId),
            gte(usageDays.day, from),
            lte(usageDays.day, to),
          ),
        );

      // Still an upsert: a payload that repeats a (day, model) inside one request would
      // otherwise fail on the primary key rather than settling on its last value.
      await tx
        .insert(usageDays)
        .values(values)
        .onConflictDoUpdate({
          target: [usageDays.builderId, usageDays.day, usageDays.model],
          set: {
            inputTokens: sql`excluded.input_tokens`,
            outputTokens: sql`excluded.output_tokens`,
            cacheReadTokens: sql`excluded.cache_read_tokens`,
            cacheWriteTokens: sql`excluded.cache_write_tokens`,
            costUsd: sql`excluded.cost_usd`,
            focusSeconds: sql`excluded.focus_seconds`,
            sessions: sql`excluded.sessions`,
            updatedAt: sql`now()`,
          },
        });

      await tx
        .update(builders)
        .set({ publishedAt: sql`now()` })
        .where(eq(builders.id, builderId));
    });

    return values.length;
  }

  private async facts(from: string | null, to: string, handle?: string): Promise<DayFact[]> {
    const conditions = [lte(usageDays.day, to)];
    if (from !== null) conditions.push(gte(usageDays.day, from));
    if (handle) conditions.push(eq(builders.handle, handle));

    const rows = await this.db
      .select({
        handle: builders.handle,
        day: usageDays.day,
        model: usageDays.model,
        inputTokens: usageDays.inputTokens,
        outputTokens: usageDays.outputTokens,
        cacheReadTokens: usageDays.cacheReadTokens,
        cacheWriteTokens: usageDays.cacheWriteTokens,
        costUsd: usageDays.costUsd,
        focusSeconds: usageDays.focusSeconds,
        sessions: usageDays.sessions,
      })
      .from(usageDays)
      .innerJoin(builders, eq(builders.id, usageDays.builderId))
      .where(and(...conditions));

    return rows.map((row) => ({ ...row, day: String(row.day) }));
  }

  private async publicBuilders(): Promise<Map<string, BuilderPublic>> {
    const rows = await this.db
      .select({
        handle: builders.handle,
        displayName: builders.displayName,
        avatarUrl: builders.avatarUrl,
        team: builders.team,
        agent: builders.agent,
      })
      .from(builders)
      .where(eq(builders.visibility, "public"));
    return new Map(rows.map((row) => [row.handle, row]));
  }

  async leaderboard(board: BoardKind, period: Period, you: string | null): Promise<Leaderboard> {
    const [facts, cast] = await Promise.all([
      this.facts(period.start, period.end),
      this.publicBuilders(),
    ]);
    const rows = rankBuilders(facts, cast);
    const totals = rows.reduce(
      (sum, row) => ({
        builders: sum.builders + 1,
        outputTokens: sum.outputTokens + row.outputTokens,
        costUsd: sum.costUsd + row.costUsd,
      }),
      { builders: 0, outputTokens: 0, costUsd: 0 },
    );
    return {
      mode: this.mode,
      board,
      period,
      rows,
      guilds: rankGuilds(rows),
      you: rows.find((row) => row.handle === you) ?? null,
      totals: { ...totals, costUsd: round2(totals.costUsd) },
    };
  }

  async profile(handle: string, range: ProfileRange): Promise<Profile | null> {
    const found = await this.db
      .select({
        handle: builders.handle,
        displayName: builders.displayName,
        avatarUrl: builders.avatarUrl,
        team: builders.team,
        agent: builders.agent,
        visibility: builders.visibility,
        createdAt: builders.createdAt,
      })
      .from(builders)
      .where(eq(builders.handle, handle))
      .limit(1);
    const builder = found[0];
    if (!builder) return null;

    const today = toISODate(new Date());
    const from = profileRangeStart(range);
    const heatmapFrom = toISODate(addDays(parseISODate(today), -364));

    const [ranged, wholeYear, lifetime] = await Promise.all([
      this.facts(from, today, handle),
      this.facts(heatmapFrom, today, handle),
      this.facts(null, today, handle),
    ]);

    const week = resolvePeriod("week", 0);
    const board = await this.leaderboard("week", week, handle);
    const position = board.rows.findIndex((row) => row.handle === handle);

    return {
      mode: this.mode,
      builder: {
        handle: builder.handle,
        displayName: builder.displayName,
        avatarUrl: builder.avatarUrl,
        team: builder.team,
        agent: builder.agent,
        visibility: builder.visibility,
        createdAt: builder.createdAt.toISOString(),
      },
      range,
      totals: {
        tokens: ranged.reduce(
          (sum, fact) =>
            sum +
            fact.inputTokens +
            fact.outputTokens +
            fact.cacheReadTokens +
            fact.cacheWriteTokens,
          0,
        ),
        outputTokens: ranged.reduce((sum, fact) => sum + fact.outputTokens, 0),
        costUsd: round2(ranged.reduce((sum, fact) => sum + fact.costUsd, 0)),
        activeDays: activeDays(ranged).length,
        longestStreakDays: streakOf(lifetime),
        sessions: ranged.reduce((sum, fact) => sum + fact.sessions, 0),
      },
      activity: dailyActivity(wholeYear, heatmapFrom, today),
      byModel: splitByModel(ranged),
      rank: { board: "week", position: position >= 0 ? position + 1 : null, of: board.rows.length },
    };
  }

  async close(): Promise<void> {
    await this.sql.end({ timeout: 5 });
  }
}

/**
 * The token is the credential and it is shown once. Only its digest is stored, so a dump
 * of the table cannot be replayed against the API.
 */
function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `perch_${base64url(bytes)}`;
}

export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Drizzle wraps driver errors in a `DrizzleQueryError`, so the SQLSTATE that says "that
 * handle is taken" is one `cause` deeper than where you would look for it. Checking only
 * the outer object turns a 409 into a 500 — which reads as "the server is broken" when the
 * truth is "pick another name".
 */
function isUniqueViolation(error: unknown): boolean {
  for (let current = error; current; current = (current as { cause?: unknown }).cause) {
    if (typeof current !== "object") break;
    if ((current as { code?: string }).code === "23505") return true;
  }
  return false;
}
