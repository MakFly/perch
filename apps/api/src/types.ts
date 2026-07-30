import type { BoardKind, Period, ProfileRange } from "./period.js";

/** What a client is told about where the numbers come from. */
export type Mode = "postgres" | "demo";

export interface BuilderPublic {
  handle: string;
  displayName: string;
  avatarUrl: string | null;
  team: string | null;
  agent: string;
}

export interface LeaderboardRow extends BuilderPublic {
  rank: number;
  /** The model that produced most of this builder's output over the period. */
  model: string;
  outputTokens: number;
  totalTokens: number;
  costUsd: number;
  focusSeconds: number;
  sessions: number;
}

export interface GuildRow {
  rank: number;
  team: string;
  members: number;
  outputTokens: number;
  costUsd: number;
  focusSeconds: number;
  sessions: number;
}

export interface Leaderboard {
  mode: Mode;
  board: BoardKind;
  period: Period;
  rows: LeaderboardRow[];
  guilds: GuildRow[];
  /** The reader's own row, when they identified themselves with `?you=<handle>`. */
  you: LeaderboardRow | null;
  totals: {
    builders: number;
    outputTokens: number;
    costUsd: number;
  };
}

export interface ModelSplit {
  model: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
}

export interface ActivityDay {
  day: string;
  tokens: number;
  costUsd: number;
}

export interface Profile {
  mode: Mode;
  builder: BuilderPublic & { visibility: string; createdAt: string };
  range: ProfileRange;
  totals: {
    tokens: number;
    outputTokens: number;
    costUsd: number;
    activeDays: number;
    longestStreakDays: number;
    sessions: number;
  };
  /** One year of daily buckets for the heatmap, oldest first, gaps filled with zeroes. */
  activity: ActivityDay[];
  byModel: ModelSplit[];
  rank: { board: "week"; position: number | null; of: number } | null;
}

export interface PublishDay {
  day: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  costUsd: number;
  focusSeconds: number;
  sessions: number;
}

export interface RegisterInput {
  handle: string;
  displayName?: string;
  avatarUrl?: string | null;
  team?: string | null;
  agent?: string;
  visibility?: "public" | "private";
}

export interface Registration {
  handle: string;
  token: string;
}

/** What the limiter says about one request. `retryAfter` is in whole seconds. */
export interface RateVerdict {
  allowed: boolean;
  retryAfter: number;
}

/**
 * What the routes are allowed to ask of storage.
 *
 * Two implementations satisfy it — Postgres, and a seeded demo set for a deployment with
 * no database attached. The routes never learn which one they got; `mode` is reported to
 * the client instead, because a demo board that presents itself as real is worse than no
 * board at all.
 */
export interface LeaderboardRepo {
  readonly mode: Mode;
  register(input: RegisterInput): Promise<Registration>;
  /** Returns the builder id for a bearer token, or null. */
  authenticate(token: string): Promise<string | null>;
  publish(builderId: string, days: PublishDay[]): Promise<number>;
  /**
   * Counts one hit against `bucket` and says whether it is still within the allowance.
   *
   * Called before the work it protects, so it is on the hot path of every write: one
   * upsert, no transaction, no read-then-write race.
   */
  take(bucket: string, limit: number, windowSeconds: number): Promise<RateVerdict>;
  leaderboard(board: BoardKind, period: Period, you: string | null): Promise<Leaderboard>;
  profile(handle: string, range: ProfileRange): Promise<Profile | null>;
  close(): Promise<void>;
}
