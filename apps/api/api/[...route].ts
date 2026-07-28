/**
 * The API as its own Vercel project.
 *
 * Root Directory is `apps/api`, so Vercel scans this `api/` folder. Everything lands under
 * `/api`; `vercel.json` rewrites `/v1/*` onto it so both the site and the Mac app can keep
 * asking for `/v1/leaderboard`.
 *
 * **The adapter is `@hono/node-server/vercel`, not `hono/vercel`.** The latter returns a
 * web-standard `(Request) => Response` handler, which is what Next.js and the Edge runtime
 * want. The `api/` directory is built by `@vercel/node`, which calls the default export
 * with `(req, res)` — hand it a fetch handler and the invocation simply never writes a
 * response: the request hangs for the full function timeout and then reports a platform
 * error. That is a much quieter failure than a crash, and it looked exactly like a routing
 * problem for an afternoon.
 */

import { handle } from "@hono/node-server/vercel";
import { Hono } from "hono";

import { createApp } from "../src/app.js";
import { makeRepo, VERSION } from "../src/index.js";

export const config = { runtime: "nodejs" };

const api = createApp({ repo: makeRepo(), version: VERSION });

// Mounted twice on purpose: `/api/v1/…` is where Vercel's filesystem routing delivers it,
// and `/v1/…` is what arrives when a rewrite preserved the original path. Matching both
// costs one line and removes a whole class of "which path did the platform give me".
const app = new Hono().route("/api", api).route("/", api);

export default handle(app);
