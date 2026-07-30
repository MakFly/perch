/**
 * The board with no database behind it.
 *
 * A deployment without `DATABASE_URL` still has to render something, or the site is a
 * spinner. This generates a fixed cast of builders and a year of plausible daily counters
 * from a seeded generator — no `Math.random`, so two requests a second apart return the
 * same numbers and the page does not shuffle under the reader.
 *
 * Every handle here is invented. Putting real people's names on fabricated statistics on a
 * public URL is not a demo, it is a claim about them. `mode: "demo"` travels with every
 * response and the UI says so on screen.
 */

import {
  activeDays,
  dailyActivity,
  rankBuilders,
  rankGuilds,
  splitByModel,
  streakOf,
  type DayFact,
} from "../aggregate.js";
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
  Registration,
  RegisterInput,
} from "../types.js";

interface Seed extends BuilderPublic {
  /** Relative output volume. The cast is meant to look like a real board, not a ladder. */
  weight: number;
  models: string[];
}

// Everyone runs more than one model, because everyone does: a cheap one for the small
// edits and an expensive one for the hard turn. A cast where each builder has exactly one
// model makes the profile page's two model lists rank identically, which hides the very
// inversion they exist to show.
const CAST: Seed[] = [
  { handle: "vega", displayName: "Vega", avatarUrl: null, team: "Nimbus", agent: "claude", weight: 100, models: ["Opus 5", "Sonnet 5", "Haiku 4.5"] },
  { handle: "solenne", displayName: "Solenne", avatarUrl: null, team: "Atelier 9", agent: "claude", weight: 84, models: ["Opus 5", "Haiku 4.5", "Fable 5"] },
  { handle: "kito", displayName: "Kito", avatarUrl: null, team: "Nimbus", agent: "codex", weight: 71, models: ["Opus 5", "Fable 5", "Sonnet 5"] },
  { handle: "marlow", displayName: "Marlow", avatarUrl: null, team: null, agent: "claude", weight: 63, models: ["Opus 5", "Sonnet 5"] },
  { handle: "ondine", displayName: "Ondine", avatarUrl: null, team: "Atelier 9", agent: "gemini", weight: 55, models: ["Fable 5", "Opus 5", "Haiku 4.5"] },
  { handle: "brann", displayName: "Brann", avatarUrl: null, team: "Corvid", agent: "claude", weight: 48, models: ["Sonnet 5", "Opus 5", "Haiku 4.5"] },
  { handle: "yuna", displayName: "Yuna", avatarUrl: null, team: "Corvid", agent: "codex", weight: 41, models: ["Opus 5", "Haiku 4.5"] },
  { handle: "pavel", displayName: "Pavel", avatarUrl: null, team: null, agent: "claude", weight: 35, models: ["Sonnet 5", "Fable 5"] },
  { handle: "iris", displayName: "Iris", avatarUrl: null, team: "Nimbus", agent: "claude", weight: 29, models: ["Opus 5", "Haiku 4.5"] },
  { handle: "temo", displayName: "Temo", avatarUrl: null, team: "Corvid", agent: "opencode", weight: 24, models: ["Fable 5", "Sonnet 5"] },
  { handle: "clio", displayName: "Clio", avatarUrl: null, team: null, agent: "claude", weight: 19, models: ["Sonnet 5", "Haiku 4.5"] },
  { handle: "rask", displayName: "Rask", avatarUrl: null, team: "Atelier 9", agent: "cursor", weight: 14, models: ["Opus 5", "Sonnet 5"] },
  { handle: "nell", displayName: "Nell", avatarUrl: null, team: null, agent: "claude", weight: 9, models: ["Haiku 4.5", "Sonnet 5"] },
  { handle: "orso", displayName: "Orso", avatarUrl: null, team: "Corvid", agent: "codex", weight: 5, models: ["Sonnet 5", "Haiku 4.5"] },
];

/** Cost per million output tokens, only so the demo's dollars track its tokens. */
const RATE_PER_MTOK: Record<string, number> = {
  "Opus 5": 25,
  "Fable 5": 50,
  "Sonnet 5": 15,
  "Haiku 4.5": 4,
};

/** A small deterministic generator — same seed, same sequence, on every machine. */
function mulberry(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(text: string): number {
  let value = 2166136261;
  for (let i = 0; i < text.length; i += 1) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 16777619);
  }
  return value >>> 0;
}

const HORIZON_DAYS = 400;

export class DemoRepo implements LeaderboardRepo {
  readonly mode = "demo" as const;

  private readonly today: string;
  private readonly facts: DayFact[];
  private readonly builders = new Map<string, BuilderPublic>();
  /** The rate limiter's counters, one live window per bucket. */
  private readonly hits = new Map<string, { startedAt: number; hits: number }>();

  constructor(now = new Date()) {
    this.today = toISODate(now);
    this.facts = [];
    for (const seed of CAST) {
      const { weight, models, ...pub } = seed;
      this.builders.set(seed.handle, pub);
      this.facts.push(...this.generate(seed, now));
    }
  }

  private generate(seed: Seed, now: Date): DayFact[] {
    const random = mulberry(hash(seed.handle));
    const out: DayFact[] = [];
    const start = addDays(parseISODate(this.today), -(HORIZON_DAYS - 1));

    for (let index = 0; index < HORIZON_DAYS; index += 1) {
      const date = addDays(start, index);
      const day = toISODate(date);
      const weekday = date.getUTCDay();

      // Quiet weekends, and a ramp so the heatmap is denser near today — a year of
      // uniform noise reads as a texture rather than as someone's habits.
      const weekendDrag = weekday === 0 || weekday === 6 ? 0.25 : 1;
      const ramp = 0.35 + (0.65 * index) / HORIZON_DAYS;
      const roll = random();
      if (roll > 0.82 * weekendDrag * ramp) continue;

      const intensity = (0.35 + random() * 0.9) * weekendDrag * ramp;
      const model = seed.models[Math.floor(random() * seed.models.length)] ?? seed.models[0]!;
      // Scaled so a busy week lands in the millions of output tokens, which is what a
      // real board of people running agents all day actually looks like.
      const output = Math.round(seed.weight * 62_000 * intensity);
      const input = Math.round(output * (7 + random() * 6));
      const cacheRead = Math.round(input * (2 + random() * 4));
      const cacheWrite = Math.round(input * 0.35);
      const rate = RATE_PER_MTOK[model] ?? 15;

      out.push({
        handle: seed.handle,
        day,
        model,
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: cacheWrite,
        costUsd: (output * rate) / 1_000_000 + (cacheRead * rate) / 40_000_000,
        focusSeconds: Math.round(1800 + intensity * 12_000),
        sessions: 1 + Math.floor(random() * 3),
      });
    }
    return out;
  }

  private within(from: string | null, to: string, handle?: string): DayFact[] {
    return this.facts.filter(
      (fact) =>
        (!handle || fact.handle === handle) &&
        (from === null || fact.day >= from) &&
        fact.day <= to,
    );
  }

  /**
   * The generated cast, for `bun run db:seed`.
   *
   * Seeding a local Postgres with the same numbers the demo mode shows means the two
   * modes can be compared side by side — which is how you notice that only one of them
   * rounds a total.
   */
  export(): { builders: BuilderPublic[]; facts: DayFact[] } {
    return { builders: [...this.builders.values()], facts: this.facts };
  }

  async register(_input: RegisterInput): Promise<Registration> {
    throw new DemoReadOnly();
  }

  async authenticate(_token: string): Promise<string | null> {
    return null;
  }

  async publish(_builderId: string, _days: PublishDay[]): Promise<number> {
    throw new DemoReadOnly();
  }

  /**
   * In memory, which is honest about what this repo is: a demo deployment is one process
   * and one seeded dataset. It exists so the routes have one limiter to call whichever
   * storage answered, and so the limits can be tested without a database.
   */
  async take(bucket: string, limit: number, windowSeconds: number): Promise<RateVerdict> {
    const now = Date.now();
    const window = Math.max(1, Math.floor(windowSeconds)) * 1000;
    const startedAt = Math.floor(now / window) * window;
    const retryAfter = Math.max(1, Math.ceil((startedAt + window - now) / 1000));

    const seen = this.hits.get(bucket);
    const hits = seen && seen.startedAt === startedAt ? seen.hits + 1 : 1;
    this.hits.set(bucket, { startedAt, hits });

    return { allowed: hits <= limit, retryAfter };
  }

  async leaderboard(board: BoardKind, period: Period, you: string | null): Promise<Leaderboard> {
    const facts = this.within(period.start, period.end);
    const rows = rankBuilders(facts, this.builders);
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
      totals: { ...totals, costUsd: Math.round(totals.costUsd * 100) / 100 },
    };
  }

  async profile(handle: string, range: ProfileRange): Promise<Profile | null> {
    const builder = this.builders.get(handle);
    if (!builder) return null;

    const from = profileRangeStart(range, parseISODate(this.today));
    const facts = this.within(from, this.today, handle);
    const heatmapFrom = toISODate(addDays(parseISODate(this.today), -364));
    const week = resolvePeriod("week", 0, parseISODate(this.today));
    const weekRows = rankBuilders(this.within(week.start, week.end), this.builders);
    const position = weekRows.findIndex((row) => row.handle === handle);

    const tokens = facts.reduce(
      (sum, fact) =>
        sum +
        fact.inputTokens +
        fact.outputTokens +
        fact.cacheReadTokens +
        fact.cacheWriteTokens,
      0,
    );

    return {
      mode: this.mode,
      builder: { ...builder, visibility: "public", createdAt: `${heatmapFrom}T00:00:00.000Z` },
      range,
      totals: {
        tokens,
        outputTokens: facts.reduce((sum, fact) => sum + fact.outputTokens, 0),
        costUsd: Math.round(facts.reduce((sum, fact) => sum + fact.costUsd, 0) * 100) / 100,
        activeDays: activeDays(facts).length,
        longestStreakDays: streakOf(this.within(null, this.today, handle)),
        sessions: facts.reduce((sum, fact) => sum + fact.sessions, 0),
      },
      activity: dailyActivity(this.within(heatmapFrom, this.today, handle), heatmapFrom, this.today),
      byModel: splitByModel(facts),
      rank: { board: "week", position: position >= 0 ? position + 1 : null, of: weekRows.length },
    };
  }

  async close(): Promise<void> {}
}

/** Thrown by writes in demo mode, so the route can answer 503 rather than pretend. */
export class DemoReadOnly extends Error {
  constructor() {
    super("this deployment has no database attached — publishing is disabled");
    this.name = "DemoReadOnly";
  }
}
