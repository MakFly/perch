import { useMemo, useState } from "react"

import type { ActivityDay } from "@/lib/api"
import { dayLabel, dollars, monthLabel, tokens } from "@/lib/format"
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

  const [hovered, setHovered] = useState<Cell | null>(null)

  return (
    <div>
      <div className="overflow-x-auto pb-1">
        <div className="min-w-[680px]">
          <div className="flex gap-[3px]" onMouseLeave={() => setHovered(null)}>
            {weeks.map((week, index) => (
              <div key={index} className="flex flex-col gap-[3px]">
                {week.map((cell, row) =>
                  cell ? (
                    <Cell
                      key={cell.day}
                      cell={cell}
                      thresholds={thresholds}
                      isHovered={hovered?.day === cell.day}
                      onEnter={setHovered}
                    />
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

      <Readout cell={hovered} />
    </div>
  )
}

/**
 * What the hovered day was, on a line of its own under the calendar.
 *
 * This replaced a floating tooltip, and the reason is the one the app's own token chart
 * already recorded: a tooltip that covers the chart it describes makes you move the mouse
 * to read it. Here it was worse than that — the calendar scrolls horizontally, and
 * `overflow-x` clips vertically too, so a tooltip anchored above a cell was cut in half by
 * the very container that lets the year scroll. Nothing to position, nothing to clip.
 *
 * Fixed height, so the block below it does not jump when the cursor enters the grid.
 */
function Readout({ cell }: { cell: Cell | null }) {
  return (
    <div className="mt-3 flex h-5 items-center gap-2 border-t border-line pt-3 text-xs">
      {cell ? (
        <>
          <span className="text-ink">{dayLabel(cell.day)}</span>
          {cell.tokens > 0 ? (
            <span className="font-mono tabular text-ink-3">
              <span className="text-info">{tokens(cell.tokens)}</span> jetons ·{" "}
              <span className="text-claude">{dollars(cell.costUsd)}</span>
            </span>
          ) : (
            <span className="text-ink-3">aucune activité</span>
          )}
        </>
      ) : (
        <span className="text-ink-3">Survole un jour pour le détail.</span>
      )}

      <span className="ml-auto flex items-center gap-1.5 text-ink-3">
        moins
        {LEVELS.map((level) => (
          <span key={level} className={cn("size-[9px] rounded-[2px]", level)} />
        ))}
        plus
      </span>
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

interface CellProps {
  cell: Cell
  thresholds: number[]
  isHovered: boolean
  onEnter: (cell: Cell) => void
}

/**
 * No `title` attribute.
 *
 * The native tooltip takes a second to appear, cannot be styled, and renders a date in the
 * browser's locale next to a figure formatted in the page's — which on a calendar of three
 * hundred cells is the difference between something you read and something you wait for.
 */
function Cell({ cell, thresholds, isHovered, onEnter }: CellProps) {
  let level = 0
  if (cell.value > 0) {
    level = 1
    for (const threshold of thresholds) if (cell.value >= threshold) level += 1
  }
  const isActive = cell.tokens > 0

  return (
    <span
      // Only the days with something on them are announced or reachable by keyboard. The
      // `title` this replaced was the only thing a screen reader had to go on, so dropping
      // it without a label would have been a regression — but reading out three hundred
      // "no activity" squares is not an improvement either.
      {...(isActive
        ? {
            role: "img",
            tabIndex: 0,
            "aria-label": `${dayLabel(cell.day)} — ${tokens(cell.tokens)} jetons, ${dollars(cell.costUsd)}`,
          }
        : { "aria-hidden": true })}
      className={cn(
        "size-[11px] rounded-[2px] transition-shadow outline-none",
        LEVELS[Math.min(4, level)],
        isHovered && "ring-1 ring-ink/70",
      )}
      onMouseEnter={() => onEnter(cell)}
      onFocus={() => onEnter(cell)}
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
