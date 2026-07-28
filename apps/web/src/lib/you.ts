/**
 * Which row is yours.
 *
 * The board is public and has no accounts, so "you" is a handle the reader tells the site
 * once — from the Mac app's Rank tab, which links here with `?you=<handle>`. It is kept in
 * `localStorage` so the highlight survives a reload, and it is only ever used to decorate
 * a row that is already public.
 */

const KEY = "perch.you"

export function readYou(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    // Safari in private mode throws on access rather than returning null.
    return null
  }
}

export function writeYou(handle: string | null): void {
  try {
    if (handle) localStorage.setItem(KEY, handle)
    else localStorage.removeItem(KEY)
  } catch {
    /* nothing to do — the highlight is a convenience, not a feature */
  }
}

/** `?you=` in the URL wins over what was stored, and is then remembered. */
export function resolveYou(search: string): string | null {
  const fromUrl = new URLSearchParams(search).get("you")?.trim().toLowerCase()
  if (fromUrl) {
    writeYou(fromUrl)
    return fromUrl
  }
  return readYou()
}

const AGENT_COLOURS: Record<string, string> = {
  claude: "text-claude",
  codex: "text-ink-2",
  gemini: "text-info",
  opencode: "text-active",
  cursor: "text-warning",
}

export function agentColour(agent: string): string {
  return AGENT_COLOURS[agent] ?? "text-ink-3"
}
