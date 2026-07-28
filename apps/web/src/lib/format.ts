/**
 * Number formatting for a board people scan rather than read.
 *
 * Every figure here is compared against the one above it, so the rules are about keeping
 * columns comparable: fixed widths through tabular numerals, one significant decimal at
 * most, and never a unit that changes halfway down a column.
 */

const FR = "fr-FR"

/** `8.4M`, `1.5M`, `640K`, `6.8B` — the compact form used in the token columns. */
export function tokens(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0"
  const units: [number, string][] = [
    [1e12, "T"],
    [1e9, "B"],
    [1e6, "M"],
    [1e3, "K"],
  ]
  for (const [size, suffix] of units) {
    if (value >= size) {
      const scaled = value / size
      // Two digits of precision, so `8.4M` and `12M` sit at the same visual width.
      return `${scaled >= 10 ? Math.round(scaled) : Math.round(scaled * 10) / 10}${suffix}`
    }
  }
  return new Intl.NumberFormat(FR, { maximumFractionDigits: 0 }).format(value)
}

/**
 * `$211`, `$4.85`.
 *
 * Cents matter under a hundred dollars and are noise above it — a column of `$211.37`
 * takes four characters more to say the same thing.
 */
export function dollars(value: number): string {
  return money(value, Math.abs(value) >= 100 ? 0 : 2)
}

/**
 * A formatter for a whole column, decided once from its largest value.
 *
 * Per-value precision reads as a mistake when the rows sit under each other: `$66.84`
 * above `$108` looks like two different quantities rather than two amounts of the same
 * thing. The column picks one precision and every row keeps it.
 */
export function dollarsIn(values: number[]): (value: number) => string {
  const peak = values.reduce((max, value) => Math.max(max, Math.abs(value)), 0)
  const digits = peak >= 100 ? 0 : 2
  return (value) => money(value, digits)
}

function money(value: number, digits: number): string {
  if (!Number.isFinite(value)) return "$0"
  return `$${new Intl.NumberFormat("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value)}`
}

/** `11h`, `8.9h`, `42min` — focus time, at the precision it was measured. */
export function duration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—"
  const hours = seconds / 3600
  if (hours < 1) return `${Math.round(seconds / 60)}min`
  return `${hours >= 10 ? Math.round(hours) : Math.round(hours * 10) / 10}h`
}

/** `1 284` — plain counts, French grouping. */
export function count(value: number): string {
  return new Intl.NumberFormat(FR, { maximumFractionDigits: 0 }).format(value)
}

const DAY_LABEL = new Intl.DateTimeFormat(FR, {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "UTC",
})

export function dayLabel(day: string): string {
  return DAY_LABEL.format(new Date(`${day}T00:00:00Z`))
}

const MONTH_SHORT = new Intl.DateTimeFormat(FR, { month: "short", timeZone: "UTC" })

export function monthLabel(day: string): string {
  return MONTH_SHORT.format(new Date(`${day}T00:00:00Z`))
}

/** `#1` for the podium, `#12` past it. */
export function rankLabel(rank: number): string {
  return `#${rank}`
}

export const MEDALS: Record<number, string> = { 1: "🥇", 2: "🥈", 3: "🥉" }

/** Two letters for an avatar with no picture behind it. */
export function initials(name: string): string {
  const parts = name.trim().split(/[\s_-]+/).filter(Boolean)
  if (parts.length === 0) return "?"
  if (parts.length === 1) return parts[0]!.slice(0, 2).toUpperCase()
  return `${parts[0]![0]}${parts[1]![0]}`.toUpperCase()
}
