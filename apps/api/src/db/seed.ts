/**
 * Fills the local database with the demo cast.
 *
 *     cd apps/api && bun run db:seed
 *
 * For working on the site against a real Postgres rather than the generated set: the API
 * then reports `mode: "postgres"` and every read goes through the same SQL the deployed
 * one will. Refuses to run against anything that is not obviously local — a seed script
 * that can reach production is a seed script that eventually does.
 */

import { DemoRepo } from "../repo/demo.js";
import { PostgresRepo } from "../repo/postgres.js";
import type { PublishDay } from "../types.js";

const url = process.env.DATABASE_URL ?? process.env.POSTGRES_URL;
if (!url) {
  console.error("DATABASE_URL is not set — run ./scripts/setup.sh first");
  process.exit(1);
}
if (!/@(localhost|127\.0\.0\.1|host\.docker\.internal)[:/]/.test(url)) {
  console.error(`refusing to seed a database that is not local: ${url.replace(/:[^:@]*@/, ":***@")}`);
  process.exit(1);
}

const demo = new DemoRepo();
const { builders, facts } = demo.export();
const repo = new PostgresRepo(url);

try {
  for (const builder of builders) {
    let token: string;
    try {
      ({ token } = await repo.register({
        handle: builder.handle,
        displayName: builder.displayName,
        team: builder.team,
        agent: builder.agent,
      }));
    } catch (error) {
      // Already seeded. The token was shown once and is gone, so this builder is left
      // exactly as it is rather than duplicated under a second handle.
      console.log(`  ${builder.handle} — already present, skipped`);
      continue;
    }

    const days: PublishDay[] = facts
      .filter((fact) => fact.handle === builder.handle)
      .map((fact) => ({
        day: fact.day,
        model: fact.model,
        inputTokens: fact.inputTokens,
        outputTokens: fact.outputTokens,
        cacheReadTokens: fact.cacheReadTokens,
        cacheWriteTokens: fact.cacheWriteTokens,
        costUsd: fact.costUsd,
        focusSeconds: fact.focusSeconds,
        sessions: fact.sessions,
      }));

    // Chunked: one statement with 400 days of rows in it is a statement Postgres will
    // parse but nobody will be able to read in a log.
    for (let index = 0; index < days.length; index += 100) {
      await repo.publish(await idOf(repo, token), days.slice(index, index + 100));
    }
    console.log(`  ${builder.handle} — ${days.length} days`);
  }
  console.log("seeded");
} finally {
  await repo.close();
}

async function idOf(repo: PostgresRepo, token: string): Promise<string> {
  const id = await repo.authenticate(token);
  if (!id) throw new Error("the token just issued does not authenticate");
  return id;
}
