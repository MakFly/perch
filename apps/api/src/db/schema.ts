import { sql } from "drizzle-orm";
import {
  bigint,
  date,
  doublePrecision,
  index,
  integer,
  pgTable,
  primaryKey,
  text,
  timestamp,
} from "drizzle-orm/pg-core";

/**
 * Someone who publishes counters. The row carries no email, no machine identifier and
 * nothing the Mac app has not been explicitly told to send: a handle, a display name, and
 * the hash of the token that authorises writes.
 */
export const builders = pgTable("builders", {
  id: text("id").primaryKey(),
  handle: text("handle").notNull().unique(),
  displayName: text("display_name").notNull(),
  avatarUrl: text("avatar_url"),
  /** Free-text team label — what the reference calls a guild. */
  team: text("team"),
  /** The agent this builder publishes from: claude, codex, gemini… */
  agent: text("agent").notNull().default("claude"),
  /** `public` shows up in the board; `private` publishes but stays unlisted. */
  visibility: text("visibility").notNull().default("public"),
  tokenHash: text("token_hash").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  publishedAt: timestamp("published_at", { withTimezone: true }),
});

/**
 * One row per (builder, day, model).
 *
 * The primary key is the whole tuple on purpose: republishing a day is an upsert, so a
 * client that re-sends the last 30 days every hour — which is exactly what the Mac app
 * does — can never inflate a total. Perch learned this the expensive way locally, where
 * 56% of transcript usage lines are duplicates.
 *
 * Token counts are `bigint`: a busy month is billions of tokens, and `integer` tops out
 * at 2.1 billion.
 */
export const usageDays = pgTable(
  "usage_days",
  {
    builderId: text("builder_id")
      .notNull()
      .references(() => builders.id, { onDelete: "cascade" }),
    day: date("day").notNull(),
    model: text("model").notNull(),
    inputTokens: bigint("input_tokens", { mode: "number" }).notNull().default(0),
    outputTokens: bigint("output_tokens", { mode: "number" }).notNull().default(0),
    cacheReadTokens: bigint("cache_read_tokens", { mode: "number" }).notNull().default(0),
    cacheWriteTokens: bigint("cache_write_tokens", { mode: "number" }).notNull().default(0),
    costUsd: doublePrecision("cost_usd").notNull().default(0),
    focusSeconds: integer("focus_seconds").notNull().default(0),
    sessions: integer("sessions").notNull().default(0),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (table) => [
    primaryKey({ columns: [table.builderId, table.day, table.model] }),
    index("usage_days_day_idx").on(table.day),
  ],
);

/**
 * One counter per (bucket, window), which is the whole rate limiter.
 *
 * It lives in Postgres because there is nowhere else to put it: every request is a fresh
 * serverless invocation, so an in-process counter counts to one and resets. A fixed window
 * rather than a sliding one — a sliding window needs the timestamps of every hit, and the
 * question here is "is someone hammering this", which a counter answers.
 *
 * Rows for a bucket's older windows are deleted as that bucket is hit again, so the table
 * stays proportional to what is currently active rather than to everything that ever was.
 */
export const rateLimits = pgTable(
  "rate_limits",
  {
    /** What is being limited: `register:<ip>`, `publish:<builder id>`. */
    bucket: text("bucket").notNull(),
    windowStart: timestamp("window_start", { withTimezone: true }).notNull(),
    hits: integer("hits").notNull().default(0),
  },
  (table) => [
    primaryKey({ columns: [table.bucket, table.windowStart] }),
    index("rate_limits_window_idx").on(table.windowStart),
  ],
);

export type BuilderRow = typeof builders.$inferSelect;
export type UsageDayRow = typeof usageDays.$inferSelect;
