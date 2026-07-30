/**
 * The rate limiter.
 *
 * Registration is open by design, so what stands between the board and a script that takes
 * every good handle is this and only this. The counter itself is tested against the demo
 * repo — one process, one map — and the route wiring is tested through the app, because a
 * limiter that is correct and not called is not a limiter.
 *
 * The Postgres implementation of the same contract is exercised in `postgres.test.ts`,
 * where the property that matters is the one a map cannot have: two invocations counting
 * into the same window at once.
 */

import { describe, expect, test } from "bun:test";

import { createApp } from "../src/routes.js";
import { DemoRepo } from "../src/repo/demo.js";

function register(app: ReturnType<typeof createApp>, address: string) {
  return app.fetch(
    new Request("http://local/v1/builders", {
      method: "POST",
      headers: { "content-type": "application/json", "x-vercel-forwarded-for": address },
      body: JSON.stringify({ handle: "someone" }),
    }),
  );
}

describe("the counter", () => {
  test("allows exactly the allowance, then refuses", async () => {
    const repo = new DemoRepo();
    for (let i = 0; i < 3; i += 1) {
      expect((await repo.take("bucket", 3, 3_600)).allowed).toBe(true);
    }
    expect((await repo.take("bucket", 3, 3_600)).allowed).toBe(false);
  });

  test("counts each bucket apart — one address cannot spend another's", async () => {
    const repo = new DemoRepo();
    expect((await repo.take("a", 1, 3_600)).allowed).toBe(true);
    expect((await repo.take("a", 1, 3_600)).allowed).toBe(false);
    expect((await repo.take("b", 1, 3_600)).allowed).toBe(true);
  });

  test("says when to come back, and never says zero", async () => {
    const repo = new DemoRepo();
    const verdict = await repo.take("bucket", 0, 3_600);
    expect(verdict.allowed).toBe(false);
    expect(verdict.retryAfter).toBeGreaterThan(0);
    expect(verdict.retryAfter).toBeLessThanOrEqual(3_600);
  });
});

describe("registration", () => {
  test("the sixth attempt from one address in an hour is refused", async () => {
    const app = createApp({ repo: new DemoRepo(), version: "test" });

    // The demo repo cannot register at all, so these are 503s — what is being tested is
    // that they were *reached*, and that the next one is not.
    for (let i = 0; i < 5; i += 1) {
      expect((await register(app, "203.0.113.7")).status).toBe(503);
    }

    const refused = await register(app, "203.0.113.7");
    expect(refused.status).toBe(429);
    expect(Number(refused.headers.get("Retry-After"))).toBeGreaterThan(0);
    expect((await refused.json()).retryAfter).toBeGreaterThan(0);
  });

  test("one address running out does not close the door on another", async () => {
    const app = createApp({ repo: new DemoRepo(), version: "test" });
    for (let i = 0; i < 6; i += 1) await register(app, "203.0.113.7");

    expect((await register(app, "198.51.100.4")).status).toBe(503);
  });

  test("a header the caller could have written is not what identifies them", async () => {
    const app = createApp({ repo: new DemoRepo(), version: "test" });
    for (let i = 0; i < 6; i += 1) await register(app, "203.0.113.7");

    // Same platform address, a different `x-forwarded-for`: still the same bucket, because
    // the spoofable header is only read when the platform's own is absent.
    const spoofed = await app.fetch(
      new Request("http://local/v1/builders", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-vercel-forwarded-for": "203.0.113.7",
          "x-forwarded-for": "8.8.8.8",
        },
        body: JSON.stringify({ handle: "someone" }),
      }),
    );
    expect(spoofed.status).toBe(429);
  });
});

describe("publishing", () => {
  test("an unauthorised flood is counted before the token is looked up", async () => {
    const app = createApp({ repo: new DemoRepo(), version: "test" });
    const attempt = () =>
      app.fetch(
        new Request("http://local/v1/publish", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-vercel-forwarded-for": "203.0.113.9",
            authorization: "Bearer nonsense",
          },
          body: JSON.stringify({ days: [] }),
        }),
      );

    for (let i = 0; i < 60; i += 1) expect((await attempt()).status).toBe(401);
    expect((await attempt()).status).toBe(429);
  });

  test("reading the board is never limited — it is the point of the site", async () => {
    const app = createApp({ repo: new DemoRepo(), version: "test" });
    for (let i = 0; i < 80; i += 1) {
      const response = await app.fetch(
        new Request("http://local/v1/leaderboard", {
          headers: { "x-vercel-forwarded-for": "203.0.113.11" },
        }),
      );
      expect(response.status).toBe(200);
    }
  });
});
