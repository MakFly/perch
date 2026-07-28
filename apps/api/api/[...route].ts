/**
 * The API as its own Vercel project.
 *
 * Root Directory is `apps/api`, so Vercel scans this `api/` folder and there is no custom
 * `outputDirectory` to compete with it. That competition is what cost an afternoon in the
 * combined project: the lambda was built — the deployment reported `lambdas: 1` — and
 * nothing ever routed to it, so every path answered Vercel's own 404 while the site
 * beside it served perfectly.
 *
 * Everything under `/api` here; `vercel.json` rewrites `/v1/*` onto it so both the site
 * and the Mac app can keep asking for `/v1/leaderboard`.
 */

import { Hono } from "hono";
import { handle } from "hono/vercel";

import { createApp } from "../src/app.js";
import { makeRepo, VERSION } from "../src/index.js";

export const config = { runtime: "nodejs" };

const app = new Hono().route("/api", createApp({ repo: makeRepo(), version: VERSION }));

export default handle(app);
