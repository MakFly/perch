/**
 * Period arithmetic for the board.
 *
 * Everything here is UTC and string-based (`YYYY-MM-DD`). A leaderboard that silently
 * shifts its week boundary with the reader's timezone would rank two people differently
 * depending on where they opened the page, so the boundary is fixed and stated.
 */

export type BoardKind = "week" | "month" | "agents" | "guilds";

export interface Period {
  kind: "week" | "month" | "all";
  /** Inclusive, `YYYY-MM-DD`. */
  start: string;
  /** Inclusive, `YYYY-MM-DD`. */
  end: string;
  /** Human label, French, as the UI shows it: `27 juil. – 2 août`. */
  label: string;
  /** How many steps back from the current period this is. 0 is the live one. */
  offset: number;
}

const DAY_MS = 86_400_000;

export function toISODate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export function parseISODate(value: string): Date {
  return new Date(`${value}T00:00:00.000Z`);
}

export function addDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * DAY_MS);
}

/** Monday of the ISO week containing `date`. */
export function startOfISOWeek(date: Date): Date {
  const day = date.getUTCDay(); // 0 = Sunday
  const delta = day === 0 ? -6 : 1 - day;
  return addDays(new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())), delta);
}

export function startOfMonth(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1));
}

const MONTHS_SHORT = [
  "janv.",
  "févr.",
  "mars",
  "avr.",
  "mai",
  "juin",
  "juil.",
  "août",
  "sept.",
  "oct.",
  "nov.",
  "déc.",
];

const MONTHS_LONG = [
  "janvier",
  "février",
  "mars",
  "avril",
  "mai",
  "juin",
  "juillet",
  "août",
  "septembre",
  "octobre",
  "novembre",
  "décembre",
];

function weekLabel(start: Date, end: Date): string {
  const left = `${start.getUTCDate()} ${MONTHS_SHORT[start.getUTCMonth()]}`;
  const right = `${end.getUTCDate()} ${MONTHS_SHORT[end.getUTCMonth()]}`;
  return `${left} – ${right}`;
}

/**
 * Resolve a board and an offset into a concrete date range.
 *
 * `agents` and `guilds` are weekly boards — the reference navigates them week by week
 * exactly like the individual one, and a board with no time bound rewards whoever started
 * first rather than whoever is working now.
 */
export function resolvePeriod(kind: BoardKind, offset: number, now = new Date()): Period {
  const back = Number.isFinite(offset) ? Math.max(0, Math.trunc(offset)) : 0;

  if (kind === "month") {
    const anchor = startOfMonth(now);
    const start = new Date(Date.UTC(anchor.getUTCFullYear(), anchor.getUTCMonth() - back, 1));
    const end = addDays(new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1)), -1);
    return {
      kind: "month",
      start: toISODate(start),
      end: toISODate(end),
      label: `${MONTHS_LONG[start.getUTCMonth()]} ${start.getUTCFullYear()}`,
      offset: back,
    };
  }

  const start = addDays(startOfISOWeek(now), -7 * back);
  const end = addDays(start, 6);
  return {
    kind: "week",
    start: toISODate(start),
    end: toISODate(end),
    label: weekLabel(start, end),
    offset: back,
  };
}

export type ProfileRange = "24h" | "7d" | "30d" | "6m" | "1y" | "all";

export const PROFILE_RANGES: ProfileRange[] = ["24h", "7d", "30d", "6m", "1y", "all"];

export function isProfileRange(value: string): value is ProfileRange {
  return (PROFILE_RANGES as string[]).includes(value);
}

/** First day included in a profile range. `null` means "everything on record". */
export function profileRangeStart(range: ProfileRange, now = new Date()): string | null {
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  switch (range) {
    case "24h":
      return toISODate(today);
    case "7d":
      return toISODate(addDays(today, -6));
    case "30d":
      return toISODate(addDays(today, -29));
    case "6m":
      return toISODate(new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() - 6, today.getUTCDate())));
    case "1y":
      return toISODate(new Date(Date.UTC(today.getUTCFullYear() - 1, today.getUTCMonth(), today.getUTCDate())));
    case "all":
      return null;
  }
}

/**
 * Longest run of consecutive days with any activity.
 *
 * Takes days already sorted ascending and de-duplicated; returns 0 for an empty list.
 */
export function longestStreak(days: string[]): number {
  if (days.length === 0) return 0;
  let best = 1;
  let run = 1;
  for (let i = 1; i < days.length; i += 1) {
    const previous = parseISODate(days[i - 1]!).getTime();
    const current = parseISODate(days[i]!).getTime();
    if (current - previous === DAY_MS) {
      run += 1;
      best = Math.max(best, run);
    } else if (current !== previous) {
      run = 1;
    }
  }
  return best;
}
