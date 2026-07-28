/**
 * The leaderboard API, as a function inside the site's own project.
 *
 * One project, one domain, no CORS between the two halves. The static site is the
 * deployment's output; this handles `/api/*`, and `vercel.json` rewrites `/v1/*` onto it so
 * the Mac app can ask for `/v1/leaderboard` on the same host.
 *
 * Two things had to be right before this worked at all, and neither was visible locally:
 *
 *  - `apps/api/tsconfig.json` has to include the `node` types. Vercel's builder typechecks
 *    what it bundles, and without them `process.env` is an unknown name — the build
 *    reports success, emits a function, and nothing routes to it.
 *  - The adapter is `@hono/node-server/vercel`, not `hono/vercel`. The latter returns a
 *    web-standard `(Request) => Response`, right for Next.js and the Edge runtime and
 *    wrong here: `@vercel/node` calls the default export with `(req, res)`, so a fetch
 *    handler simply never writes a response and the request hangs until the timeout.
 */

import { handle } from "@hono/node-server/vercel";
import { Hono } from "hono";

import { createApp } from "../apps/api/src/routes.js";
import { makeRepo, VERSION } from "../apps/api/src/index.js";

export const config = { runtime: "nodejs" };

const api = createApp({ repo: makeRepo(), version: VERSION });

// Mounted at both, because which one arrives depends on whether a rewrite preserved the
// original path — and matching both costs a line.
const app = new Hono().route("/api", api).route("/", api);

export default handle(app);
