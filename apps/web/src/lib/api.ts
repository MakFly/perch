/**
 * The leaderboard API, typed.
 *
 * Shapes mirror `apps/api/src/types.ts`. They are restated rather than imported so the
 * site can be built and deployed on its own — Vercel builds `apps/web` alone, and a type
 * import reaching across the workspace would make that build depend on the API's
 * `tsconfig`.
 */

export type Mode = "postgres" | "demo"
export type Board = "week" | "month" | "agents" | "guilds"
export type ProfileRange = "24h" | "7d" | "30d" | "6m" | "1y" | "all"

export interface Period {
  kind: "week" | "month" | "all"
  start: string
  end: string
  label: string
  offset: number
}

export interface LeaderboardRow {
  rank: number
  handle: string
  displayName: string
  avatarUrl: string | null
  team: string | null
  agent: string
  model: string
  outputTokens: number
  totalTokens: number
  costUsd: number
  focusSeconds: number
  sessions: number
}

export interface GuildRow {
  rank: number
  team: string
  members: number
  outputTokens: number
  costUsd: number
  focusSeconds: number
  sessions: number
}

export interface Leaderboard {
  mode: Mode
  board: Board
  period: Period
  rows: LeaderboardRow[]
  guilds: GuildRow[]
  you: LeaderboardRow | null
  totals: { builders: number; outputTokens: number; costUsd: number }
}

export interface ActivityDay {
  day: string
  tokens: number
  costUsd: number
}

export interface ModelSplit {
  model: string
  inputTokens: number
  outputTokens: number
  costUsd: number
}

export interface Profile {
  mode: Mode
  builder: {
    handle: string
    displayName: string
    avatarUrl: string | null
    team: string | null
    agent: string
    visibility: string
    createdAt: string
  }
  range: ProfileRange
  totals: {
    tokens: number
    outputTokens: number
    costUsd: number
    activeDays: number
    longestStreakDays: number
    sessions: number
  }
  activity: ActivityDay[]
  byModel: ModelSplit[]
  rank: { board: "week"; position: number | null; of: number } | null
}

/**
 * Same origin, same path, in both environments.
 *
 * The site always calls `/api/v1/…`: on Vercel that is where the function lives, and in
 * development Vite proxies the prefix onto `bun run dev`'s `:8787`. Making the two
 * identical means the path the browser requests is never something only production
 * exercises. `VITE_PERCH_API` points the site at a different API without touching either.
 */
const BASE = import.meta.env.VITE_PERCH_API ?? "/api"

export class ApiError extends Error {
  readonly status: number

  constructor(message: string, status: number) {
    super(message)
    this.name = "ApiError"
    this.status = status
  }
}

async function get<T>(path: string): Promise<T> {
  const response = await fetch(`${BASE}${path}`, { headers: { Accept: "application/json" } })
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { error?: string } | null
    throw new ApiError(body?.error ?? `HTTP ${response.status}`, response.status)
  }
  return (await response.json()) as T
}

export function fetchLeaderboard(board: Board, offset: number, you: string | null) {
  const params = new URLSearchParams({ board, offset: String(offset) })
  if (you) params.set("you", you)
  return get<Leaderboard>(`/v1/leaderboard?${params}`)
}

export function fetchProfile(handle: string, range: ProfileRange) {
  return get<Profile>(`/v1/builders/${encodeURIComponent(handle)}?range=${range}`)
}

export function fetchHealth() {
  return get<{ ok: boolean; mode: Mode; version: string }>("/v1/health")
}

/**
 * The DMG, straight from the release that carries it.
 *
 * A static link and a public repository, which is the whole design: no token to hold, no
 * function to keep warm, nothing to rate-limit. `latest/download/<name>` is resolved by
 * GitHub, so the asset ships under a fixed name as well as a versioned one.
 */
export const REPO = "dev-toolings/perch"
export const DOWNLOAD_URL = `https://github.com/${REPO}/releases/latest/download/Perch.dmg`

export interface Release {
  version: string
  sizeBytes: number
}

/** What the button can say before it is clicked. Anonymous, and read straight from GitHub. */
export async function fetchRelease(): Promise<Release> {
  const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { Accept: "application/vnd.github+json" },
  })
  if (!response.ok) throw new ApiError(`HTTP ${response.status}`, response.status)

  const body = (await response.json()) as {
    tag_name?: string
    assets?: { name?: string; size?: number }[]
  }
  // The DMG, not the first asset: a release also carries notes and checksums.
  const asset = body.assets?.find((a) => a.name?.endsWith(".dmg"))
  if (!asset) throw new ApiError("no build published yet", 404)

  return { version: (body.tag_name ?? "").replace(/^v/, ""), sizeBytes: asset.size ?? 0 }
}
