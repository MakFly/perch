/**
 * Local development server.
 *
 * `bun run dev` in `apps/api`. In production the same Hono app is exported from
 * `src/index.ts` and mounted as a Vercel function by `/api/index.ts` at the repository
 * root — there is one app, and this file only gives it a socket.
 *
 * `Bun.serve` is called explicitly rather than through a default export: Bun also starts a
 * server for an exported `{ port, fetch }`, so the two together bound the port twice and
 * the second attempt died with EADDRINUSE while the first kept running — a failure that
 * looks like "something else is on 8787" and is not.
 */

import { createApp } from "./routes.js";
import { makeRepo, VERSION } from "./index.js";

const port = Number(process.env.PORT ?? 8787);
const repo = makeRepo();
const app = createApp({ repo, version: VERSION });

const server = Bun.serve({ port, fetch: app.fetch });

console.log(`perch api ${VERSION} — mode ${repo.mode} — ${server.url}`);
if (repo.mode === "demo") {
  console.log("  no DATABASE_URL: serving generated numbers, publishing disabled");
}
