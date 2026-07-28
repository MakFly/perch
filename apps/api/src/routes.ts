import { Hono, type Context } from "hono";
import { cors } from "hono/cors";

import { isProfileRange, resolvePeriod, type BoardKind } from "./period.js";
import { DemoReadOnly } from "./repo/demo.js";
import { HandleTaken, InvalidHandle } from "./repo/postgres.js";
import type { LeaderboardRepo, PublishDay } from "./types.js";

const BOARDS: BoardKind[] = ["week", "month", "agents", "guilds"];

/** How far back the board can be walked. Beyond this there is nothing to see. */
const MAX_OFFSET = 260;

/** One publish carries a rolling window, not a lifetime. */
const MAX_PUBLISH_DAYS = 800;

export interface AppOptions {
  repo: LeaderboardRepo;
  version: string;
}

export function createApp({ repo, version }: AppOptions): Hono {
  const app = new Hono();

  // The Mac app and the site are different origins by construction, and everything served
  // here is either public or authorised by a bearer token.
  app.use("/v1/*", cors({ origin: "*", allowHeaders: ["Authorization", "Content-Type"] }));

  app.get("/v1/health", (c) =>
    c.json({
      ok: true,
      /** `demo` means the numbers are generated. Clients are expected to say so. */
      mode: repo.mode,
      version,
      time: new Date().toISOString(),
    }),
  );

  app.get("/v1/leaderboard", async (c) => {
    const requested = c.req.query("board") ?? "week";
    const board = (BOARDS as string[]).includes(requested) ? (requested as BoardKind) : "week";
    const offset = clampOffset(c.req.query("offset"));
    const you = normaliseHandle(c.req.query("you"));

    // `agents` and `guilds` are weekly views of the same window; only `month` changes the
    // shape of the period.
    const period = resolvePeriod(board === "month" ? "month" : "week", offset);
    const board_ = await repo.leaderboard(board, period, you);
    return c.json(board_);
  });

  app.get("/v1/builders/:handle", async (c) => {
    const handle = normaliseHandle(c.req.param("handle"));
    if (!handle) return c.json({ error: "unknown builder" }, 404);

    const requested = c.req.query("range") ?? "30d";
    const range = isProfileRange(requested) ? requested : "30d";

    const profile = await repo.profile(handle, range);
    if (!profile) return c.json({ error: "unknown builder" }, 404);
    if (profile.builder.visibility !== "public") return c.json({ error: "unknown builder" }, 404);
    return c.json(profile);
  });

  app.post("/v1/builders", async (c) => {
    const body = await readJSON(c.req.raw);
    if (!body || typeof body.handle !== "string") {
      return c.json({ error: "handle is required" }, 400);
    }
    try {
      return c.json(
        await repo.register({
          handle: body.handle,
          displayName: asString(body.displayName),
          avatarUrl: asString(body.avatarUrl) ?? null,
          team: asString(body.team) ?? null,
          agent: asString(body.agent),
          visibility: body.visibility === "private" ? "private" : "public",
        }),
        201,
      );
    } catch (error) {
      return failure(c, error);
    }
  });

  app.post("/v1/publish", async (c) => {
    const token = bearer(c.req.header("Authorization"));
    if (!token) return c.json({ error: "missing bearer token" }, 401);

    const builderId = await repo.authenticate(token).catch(() => null);
    if (!builderId) return c.json({ error: "unknown token" }, 401);

    const body = await readJSON(c.req.raw);
    const days = parseDays(body?.days);
    if (days === null) return c.json({ error: "days must be an array of daily counters" }, 400);
    if (days.length > MAX_PUBLISH_DAYS) {
      return c.json({ error: `at most ${MAX_PUBLISH_DAYS} rows per publish` }, 413);
    }

    try {
      return c.json({ accepted: await repo.publish(builderId, days) });
    } catch (error) {
      return failure(c, error);
    }
  });

  app.notFound((c) => c.json({ error: "not found" }, 404));

  return app;
}

// MARK: - Parsing
//
// Hand-rolled rather than pulled from a schema library: the surface is four fields wide and
// every one of them ends up in a `bigint` column, where "undefined" would become NaN and
// then a row nobody can explain.

function clampOffset(value: string | undefined): number {
  const parsed = Number.parseInt(value ?? "0", 10);
  if (!Number.isFinite(parsed)) return 0;
  return Math.min(MAX_OFFSET, Math.max(0, parsed));
}

function normaliseHandle(value: string | undefined): string | null {
  const handle = value?.trim().toLowerCase();
  return handle ? handle : null;
}

function bearer(header: string | undefined): string | null {
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match?.[1]?.trim() ?? null;
}

async function readJSON(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await request.json();
    return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function count(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) return 0;
  return Math.round(parsed);
}

function amount(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

function parseDays(value: unknown): PublishDay[] | null {
  if (!Array.isArray(value)) return null;
  const out: PublishDay[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) continue;
    const row = entry as Record<string, unknown>;
    const day = typeof row.day === "string" ? row.day : "";
    const model = asString(row.model);
    if (!ISO_DAY.test(day) || !model) continue;
    out.push({
      day,
      model,
      inputTokens: count(row.inputTokens),
      outputTokens: count(row.outputTokens),
      cacheReadTokens: count(row.cacheReadTokens),
      cacheWriteTokens: count(row.cacheWriteTokens),
      costUsd: amount(row.costUsd),
      focusSeconds: count(row.focusSeconds),
      sessions: count(row.sessions),
    });
  }
  return out;
}

function failure(c: Context, error: unknown) {
  if (error instanceof DemoReadOnly) return c.json({ error: error.message }, 503);
  if (error instanceof HandleTaken) return c.json({ error: error.message }, 409);
  if (error instanceof InvalidHandle) return c.json({ error: error.message }, 400);
  console.error(error);
  return c.json({ error: "internal error" }, 500);
}
