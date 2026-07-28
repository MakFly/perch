import { createApp } from "./app.js";
import { DemoRepo } from "./repo/demo.js";
import { PostgresRepo } from "./repo/postgres.js";
import type { LeaderboardRepo } from "./types.js";

export const VERSION = "0.1.0";

/**
 * Storage is chosen by whether a database was configured, and the choice is reported
 * rather than hidden — `GET /v1/health` says `postgres` or `demo`, and every board carries
 * the same field.
 *
 * A deployment with no database still serves a board, because the alternative is a site
 * that is a spinner until someone remembers to attach one.
 */
export function makeRepo(env: Record<string, string | undefined> = process.env): LeaderboardRepo {
  const url = env.DATABASE_URL ?? env.POSTGRES_URL ?? env.PERCH_DATABASE_URL;
  return url ? new PostgresRepo(url) : new DemoRepo();
}

/** Built once per process: a serverless invocation should not open a pool per request. */
let cached: ReturnType<typeof createApp> | null = null;

export function app() {
  if (!cached) cached = createApp({ repo: makeRepo(), version: VERSION });
  return cached;
}

export default {
  fetch: (request: Request) => app().fetch(request),
};

export { createApp } from "./app.js";
export { DemoRepo } from "./repo/demo.js";
export { PostgresRepo } from "./repo/postgres.js";
