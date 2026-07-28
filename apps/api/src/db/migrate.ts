/**
 * Applies the SQL in `drizzle/` to the configured database.
 *
 * Called by `./scripts/setup.sh`, which already creates the `perch` database inside the
 * shared Postgres container. Safe to re-run: the migrator keeps its own journal table.
 */

import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";

const url = process.env.DATABASE_URL ?? process.env.POSTGRES_URL;
if (!url) {
  console.error("DATABASE_URL is not set — nothing to migrate");
  process.exit(1);
}

const sql = postgres(url, { max: 1 });
try {
  await migrate(drizzle(sql), { migrationsFolder: new URL("../../drizzle", import.meta.url).pathname });
  console.log("migrations applied");
} finally {
  await sql.end({ timeout: 5 });
}
