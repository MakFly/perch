/**
 * The Postgres path, against a real database.
 *
 * Skipped when `DATABASE_URL` is absent, so `bun test` stays green on a machine with no
 * container running. `./scripts/setup.sh` is what makes it run:
 *
 *     DATABASE_URL=postgresql://test:test@localhost:5432/perch bun test
 *
 * The property worth a real database is the upsert: the Mac app re-sends a rolling window
 * on every publish, so a second publish of the same day has to *replace* it. Get that
 * wrong and the board rewards leaving the app open.
 */

import { afterAll, describe, expect, test } from "bun:test";

import { createApp } from "../src/routes.js";
import { resolvePeriod, toISODate } from "../src/period.js";
import { PostgresRepo } from "../src/repo/postgres.js";

const url = process.env.DATABASE_URL ?? process.env.POSTGRES_URL;
const suite = url ? describe : describe.skip;

const repo = url ? new PostgresRepo(url) : null;
const app = repo ? createApp({ repo, version: "test" }) : null;
const stamp = Date.now().toString(36);
const handle = `t-${stamp}`;

afterAll(async () => {
  if (!repo) return;
  // Leave the shared database as it was found.
  await (repo as unknown as { sql: (strings: TemplateStringsArray, ...values: unknown[]) => Promise<unknown> })
    .sql`DELETE FROM builders WHERE handle LIKE 't-%'`;
  await repo.close();
});

function day(offset: number): string {
  const week = resolvePeriod("week", 0);
  const start = new Date(`${week.start}T00:00:00.000Z`);
  return toISODate(new Date(start.getTime() + offset * 86_400_000));
}

async function readJSON(path: string) {
  const response = await app!.fetch(new Request(`http://local${path}`));
  return (await response.json()) as any;
}

async function post(path: string, body: unknown, token?: string) {
  const response = await app!.fetch(
    new Request(`http://local${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    }),
  );
  return { status: response.status, body: await response.json() };
}

suite("postgres", () => {
  test("register, publish, and read the board back", async () => {
    const registered = await post("/v1/builders", {
      handle,
      displayName: "Integration",
      team: "Nimbus",
    });
    expect(registered.status).toBe(201);
    const token = registered.body.token as string;
    expect(token).toStartWith("perch_");

    const published = await post(
      "/v1/publish",
      {
        days: [
          {
            day: day(0),
            model: "Opus 5",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 10,
            cacheWriteTokens: 5,
            costUsd: 1.5,
            focusSeconds: 3600,
            sessions: 2,
          },
        ],
      },
      token,
    );
    expect(published.status).toBe(200);
    expect(published.body.accepted).toBe(1);

    const board = await readJSON(`/v1/leaderboard?board=week&you=${handle}`);
    expect(board.mode).toBe("postgres");
    expect(board.you?.outputTokens).toBe(500);
    expect(board.you?.model).toBe("Opus 5");
  });

  test("republishing the same day replaces it — a rolling window never inflates a total", async () => {
    const registered = await post("/v1/builders", { handle: `${handle}-b` });
    const token = registered.body.token as string;

    const row = {
      day: day(1),
      model: "Opus 5",
      inputTokens: 0,
      outputTokens: 400,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: 1,
      focusSeconds: 60,
      sessions: 1,
    };
    await post("/v1/publish", { days: [row] }, token);
    await post("/v1/publish", { days: [row] }, token);
    await post("/v1/publish", { days: [{ ...row, outputTokens: 900 }] }, token);

    const board = await readJSON(`/v1/leaderboard?board=week&you=${handle}-b`);
    expect(board.you?.outputTokens).toBe(900);
  });

  test("a taken handle is a 409, not a second row with the same name", async () => {
    await post("/v1/builders", { handle: `${handle}-c` });
    const again = await post("/v1/builders", { handle: `${handle}-c` });
    expect(again.status).toBe(409);
  });

  test("a handle with a slash in it is refused before it reaches a URL", async () => {
    const bad = await post("/v1/builders", { handle: "../admin" });
    expect(bad.status).toBe(400);
  });

  test("an unknown token cannot publish", async () => {
    const denied = await post("/v1/publish", { days: [] }, "perch_not-a-real-token");
    expect(denied.status).toBe(401);
  });

  test("a private builder publishes but stays off the board and off the profile page", async () => {
    const registered = await post("/v1/builders", {
      handle: `${handle}-d`,
      visibility: "private",
    });
    const token = registered.body.token as string;
    await post(
      "/v1/publish",
      {
        days: [
          {
            day: day(2),
            model: "Opus 5",
            inputTokens: 0,
            outputTokens: 10_000_000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            costUsd: 99,
            focusSeconds: 60,
            sessions: 1,
          },
        ],
      },
      token,
    );

    const board = await readJSON("/v1/leaderboard?board=week");
    expect(board.rows.some((row: { handle: string }) => row.handle === `${handle}-d`)).toBe(false);

    const profile = await app!.fetch(new Request(`http://local/v1/builders/${handle}-d`));
    expect(profile.status).toBe(404);
  });

  test("the profile reports a year of cells and the week rank", async () => {
    const profile = await readJSON(`/v1/builders/${handle}`);
    expect(profile.activity).toHaveLength(365);
    expect(profile.rank?.position).toBeGreaterThan(0);
  });
});

suite("publish is authoritative for its window", () => {
  /// Found in a real end-to-end run: the client started sending `Opus 5` where it had sent
  /// `claude-opus-5`, the model is part of the primary key, so the old rows survived the
  /// upsert and every total doubled. A publish now replaces its own day range.
  test("a row whose model was renamed does not survive the next publish", async () => {
    const registered = await post("/v1/builders", { handle: `${handle}-rename` });
    const token = registered.body.token as string;
    const base = {
      day: day(3),
      inputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: 1,
      focusSeconds: 60,
      sessions: 1,
    };

    await post("/v1/publish", { days: [{ ...base, model: "claude-opus-5", outputTokens: 500 }] }, token);
    await post("/v1/publish", { days: [{ ...base, model: "Opus 5", outputTokens: 500 }] }, token);

    const board = await readJSON(`/v1/leaderboard?board=week&you=${handle}-rename`);
    expect(board.you?.outputTokens).toBe(500);
    expect(board.you?.model).toBe("Opus 5");
  });

  test("a publish never reaches outside the days it carries", async () => {
    const registered = await post("/v1/builders", { handle: `${handle}-window` });
    const token = registered.body.token as string;
    const row = (d: string, out: number) => ({
      day: d,
      model: "Opus 5",
      inputTokens: 0,
      outputTokens: out,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      costUsd: 0,
      focusSeconds: 0,
      sessions: 1,
    });

    await post("/v1/publish", { days: [row(day(0), 100), row(day(6), 700)] }, token);
    // A later publish that only covers the first day must leave the last one alone.
    await post("/v1/publish", { days: [row(day(0), 111)] }, token);

    const board = await readJSON(`/v1/leaderboard?board=week&you=${handle}-window`);
    expect(board.you?.outputTokens).toBe(811);
  });
});
