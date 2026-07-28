import { Hono } from "hono";

import { createApp } from "./routes.js";
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

/**
 * The app itself, as Vercel's Hono preset expects it: a default-exported `Hono` instance.
 *
 * This replaced a hand-wired function in an `api/` directory, and the difference is the
 * whole story of getting this deployed. That convention wants a filename to encode the
 * route — `api/[...route].ts` — and in this project it only ever matched a single path
 * segment, so `/api/x` reached the app and `/api/v1/health` came back as the platform's
 * own 404. The preset has no filename to get wrong: Vercel routes every request here and
 * Hono decides, exactly as it does under `bun run dev`.
 *
 * Built once per process, so a serverless invocation does not open a database pool per
 * request.
 *
 * `Hono` is imported and used here rather than only in `routes.ts` because that is how the
 * builder finds this file: it refuses a deployment with "no entrypoint found which imports
 * hono", and an entry that only imports a factory does not qualify.
 */
const app = new Hono().route("/", createApp({ repo: makeRepo(), version: VERSION }));

export default app;

export { createApp } from "./routes.js";
export { DemoRepo } from "./repo/demo.js";
export { PostgresRepo } from "./repo/postgres.js";
