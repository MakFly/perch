import { useMemo } from "react"

import type { ActivityDay } from "@/lib/api"
import { dayLabel, monthLabel, tokens } from "@/lib/format"
import { cn } from "@/lib/utils"

export type HeatmapMode = "daily" | "weekly" | "cumulative"

interface Props {
  days: ActivityDay[]
  mode: HeatmapMode
}

/**
 * A year of activity, one cell per day.
 *
 * Intensity comes from where a day sits in the *distribution* of your active days, not
 * from its share of the biggest one — see `build` for why that distinction is the whole
 * difference between a calendar and a single bright square.
 */
export function Heatmap({ days, mode }: Props) {
  const { weeks, months, thresholds } = useMemo(() => build(days, mode), [days, mode])

  return (
    <div className="overflow-x-auto pb-1">
      <div className="min-w-[680px]">
        <div className="flex gap-[3px]">
          {weeks.map((week, index) => (
            <div key={index} className="flex flex-col gap-[3px]">
              {week.map((cell, row) =>
                cell ? (
                  <Cell key={cell.day} cell={cell} thresholds={thresholds} />
                ) : (
                  <span key={`pad-${row}`} className="size-[11px]" />
                ),
              )}
            </div>
          ))}
        </div>

        {/*
          Absolutely positioned rather than one label per column: a month name is far wider
          than the 14px a column occupies, so laid out in flow the labels collide and
          "juil." runs into "août".
        */}
        <div className="relative mt-2 h-4 text-[11px] text-ink-3">
          {months.map((label) => (
            <span
              key={label.text + label.column}
              className="absolute top-0 whitespace-nowrap"
              style={{ left: `${label.column * COLUMN_PITCH}px` }}
            >
              {label.text}
            </span>
          ))}
        </div>
      </div>
    </div>
  )
}

interface Cell extends ActivityDay {
  /** What the cell actually shows, which differs by mode. */
  value: number
}

interface MonthLabel {
  text: string
  column: number
}

/** Cell size plus gap — the distance from one week column to the next. */
const COLUMN_PITCH = 14

/** Columns a month label needs to itself before the next one is allowed to print. */
const MIN_LABEL_GAP = 3

function Cell({ cell, thresholds }: { cell: Cell; thresholds: number[] }) {
  let level = 0
  if (cell.value > 0) {
    level = 1
    for (const threshold of thresholds) if (cell.value >= threshold) level += 1
  }
  return (
    <span
      className={cn("size-[11px] rounded-[2px]", LEVELS[Math.min(4, level)])}
      title={`${dayLabel(cell.day)} — ${tokens(cell.tokens)} jetons`}
    />
  )
}

const LEVELS = [
  "bg-white/[0.05]",
  "bg-info/25",
  "bg-info/45",
  "bg-info/70",
  "bg-info",
] as const

function build(days: ActivityDay[], mode: HeatmapMode) {
  if (days.length === 0) {
    return { weeks: [] as (Cell | null)[][], months: [] as MonthLabel[], thresholds: [] as number[] }
  }

  // Values first, then layout. Weekly repeats a week's total across its days so the block
  // reads as a band; cumulative is a running sum, which only ever grows.
  let cells: Cell[] = days.map((day) => ({ ...day, value: day.tokens }))

  if (mode === "cumulative") {
    let running = 0
    cells = cells.map((cell) => {
      running += cell.tokens
      return { ...cell, value: running }
    })
  }

  if (mode === "weekly") {
    const totals = new Map<string, number>()
    for (const cell of cells) {
      const key = isoWeekKey(cell.day)
      totals.set(key, (totals.get(key) ?? 0) + cell.tokens)
    }
    cells = cells.map((cell) => ({ ...cell, value: totals.get(isoWeekKey(cell.day)) ?? 0 }))
  }

  // Levels come from quantiles of the active days, not from a fraction of the peak.
  //
  // One enormous day is normal — a Saturday spent on a migration is fifty times a
  // Tuesday's edits — and against a linear scale it flattens every other day to the
  // faintest level. The calendar then says "you worked once", when the truth is twenty-nine
  // active days. Splitting the *distribution* into quarters guarantees all four levels are
  // populated, so the grid reads as habits instead of as one bright square.
  const active = cells
    .map((cell) => cell.value)
    .filter((value) => value > 0)
    .sort((a, b) => a - b)
  const quantile = (fraction: number) =>
    active.length === 0 ? Infinity : active[Math.floor((active.length - 1) * fraction)]!
  const thresholds = [quantile(0.25), quantile(0.5), quantile(0.75)]

  // Columns are weeks, rows are weekdays with Monday on top. The first column is padded so
  // every column below the same month label starts on the same weekday.
  const weeks: (Cell | null)[][] = []
  let current: (Cell | null)[] = []
  const firstWeekday = weekdayIndex(cells[0]!.day)
  for (let i = 0; i < firstWeekday; i += 1) current.push(null)

  for (const cell of cells) {
    current.push(cell)
    if (current.length === 7) {
      weeks.push(current)
      current = []
    }
  }
  if (current.length > 0) {
    while (current.length < 7) current.push(null)
    weeks.push(current)
  }

  // One label per month, on the column where that month first appears — and never within
  // MIN_LABEL_GAP columns of the previous one, or a month that starts mid-week prints on
  // top of the one before it.
  const months: MonthLabel[] = []
  let previousText = ""
  let previousColumn = -MIN_LABEL_GAP
  weeks.forEach((week, column) => {
    const first = week.find((cell): cell is Cell => cell !== null)
    if (!first) return
    const text = monthLabel(first.day)
    if (text === previousText) return
    previousText = text
    if (column - previousColumn < MIN_LABEL_GAP) return
    previousColumn = column
    months.push({ text, column })
  })

  return { weeks, months, thresholds }
}

/** Monday = 0, so the grid reads the way a European calendar does. */
function weekdayIndex(day: string): number {
  const weekday = new Date(`${day}T00:00:00Z`).getUTCDay()
  return weekday === 0 ? 6 : weekday - 1
}

function isoWeekKey(day: string): string {
  const date = new Date(`${day}T00:00:00Z`)
  const offset = weekdayIndex(day)
  date.setUTCDate(date.getUTCDate() - offset)
  return date.toISOString().slice(0, 10)
}
