/**
 * The leaderboard API, as a Vercel function.
 *
 * Vercel serves everything in this directory under `/api`, so the Hono app is mounted
 * there rather than at the root — one app, two hosts, no second copy of the routes. The
 * local `bun run dev` in `apps/api` serves the identical app on `:8787` without the
 * prefix, which is what `vercel.json` rewrites `/v1/*` onto so the Mac app can keep asking
 * for `/v1/leaderboard` on either.
 *
 * The filename is an **optional catch-all** and has to be. As `api/index.ts` this function
 * answers `/api` and nothing below it, so every real request — `/api/v1/health` — came
 * back as Vercel's own 404 with no trace of the function having run. `[[...route]]` claims
 * `/api` and everything under it, which is what Hono expects to route.
 */

import { Hono } from "hono";
import { handle } from "hono/vercel";

import { createApp } from "../apps/api/src/app.js";
import { makeRepo, VERSION } from "../apps/api/src/index.js";

export const config = { runtime: "nodejs" };

const app = new Hono().route("/api", createApp({ repo: makeRepo(), version: VERSION }));

export default handle(app);
