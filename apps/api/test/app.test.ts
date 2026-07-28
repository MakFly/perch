import { describe, expect, test } from "bun:test";

import { createApp } from "../src/routes.js";
import { DemoRepo } from "../src/repo/demo.js";

const app = createApp({ repo: new DemoRepo(new Date("2026-07-28T09:00:00Z")), version: "test" });

async function get(path: string) {
  const response = await app.fetch(new Request(`http://local${path}`));
  return { status: response.status, body: await response.json() };
}

describe("health", () => {
  test("says which storage answered, so a demo board never passes for a real one", async () => {
    const { body } = await get("/v1/health");
    expect(body.mode).toBe("demo");
  });
});

describe("leaderboard", () => {
  test("returns a ranked week", async () => {
    const { status, body } = await get("/v1/leaderboard?board=week");
    expect(status).toBe(200);
    expect(body.mode).toBe("demo");
    expect(body.rows.length).toBeGreaterThan(0);
    expect(body.rows[0].rank).toBe(1);
    for (let i = 1; i < body.rows.length; i += 1) {
      expect(body.rows[i - 1].outputTokens).toBeGreaterThanOrEqual(body.rows[i].outputTokens);
    }
  });

  test("is deterministic — two reads of the same window agree", async () => {
    const first = await get("/v1/leaderboard?board=week&offset=1");
    const second = await get("/v1/leaderboard?board=week&offset=1");
    expect(first.body).toEqual(second.body);
  });

  test("an unknown board falls back to the week rather than 404ing the page", async () => {
    const { status, body } = await get("/v1/leaderboard?board=nonsense");
    expect(status).toBe(200);
    expect(body.period.kind).toBe("week");
  });

  test("`you` picks out the reader's own row", async () => {
    const { body } = await get("/v1/leaderboard?board=week&you=vega");
    expect(body.you?.handle).toBe("vega");
  });

  test("`you` for a handle that is not on the board is null, not an error", async () => {
    const { body } = await get("/v1/leaderboard?board=week&you=nobody");
    expect(body.you).toBeNull();
  });

  test("the month board covers a month", async () => {
    const { body } = await get("/v1/leaderboard?board=month");
    expect(body.period.kind).toBe("month");
    expect(body.period.start).toBe("2026-07-01");
  });

  test("guilds are ranked alongside the individual rows", async () => {
    const { body } = await get("/v1/leaderboard?board=guilds");
    expect(body.guilds.length).toBeGreaterThan(0);
    expect(body.guilds[0].members).toBeGreaterThan(0);
  });

  test("a silly offset is clamped instead of reaching into the year 1200", async () => {
    const { status, body } = await get("/v1/leaderboard?offset=99999");
    expect(status).toBe(200);
    expect(body.period.offset).toBe(260);
  });
});

describe("profile", () => {
  test("carries a year of daily cells for the heatmap", async () => {
    const { status, body } = await get("/v1/builders/vega");
    expect(status).toBe(200);
    expect(body.activity).toHaveLength(365);
    expect(body.byModel.length).toBeGreaterThan(0);
    expect(body.totals.longestStreakDays).toBeGreaterThan(0);
  });

  test("the range changes the totals but not the heatmap", async () => {
    const short = await get("/v1/builders/vega?range=7d");
    const long = await get("/v1/builders/vega?range=30d");
    expect(short.body.totals.tokens).toBeLessThan(long.body.totals.tokens);
    expect(short.body.activity).toHaveLength(365);
  });

  test("an unknown builder is a 404, not an empty profile", async () => {
    const { status } = await get("/v1/builders/nobody");
    expect(status).toBe(404);
  });
});

describe("writes in demo mode", () => {
  test("publishing without a token is refused before storage is consulted", async () => {
    const response = await app.fetch(
      new Request("http://local/v1/publish", { method: "POST", body: "{}" }),
    );
    expect(response.status).toBe(401);
  });

  test("registering says the deployment has no database rather than failing obscurely", async () => {
    const response = await app.fetch(
      new Request("http://local/v1/builders", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ handle: "someone" }),
      }),
    );
    expect(response.status).toBe(503);
    expect((await response.json()).error).toContain("no database");
  });
});
