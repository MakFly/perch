import { BuilderCell } from "@/components/builder-cell"
import type { LeaderboardRow } from "@/lib/api"
import { MEDALS, dollarsIn, duration, rankLabel, tokens } from "@/lib/format"
import { cn } from "@/lib/utils"

interface Props {
  rows: LeaderboardRow[]
  you: string | null
}

/**
 * The board itself.
 *
 * A real `<table>` rather than a grid of divs: this is tabular data, the columns are
 * compared down as much as across, and a screen reader should be able to say "row 4,
 * output 4.2M" without help.
 */
export function LeaderboardTable({ rows, you }: Props) {
  const dollars = dollarsIn(rows.map((row) => row.costUsd))

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[640px] border-separate border-spacing-y-1">
        <thead>
          <tr className="text-[11px] uppercase tracking-[0.12em] text-ink-3">
            <th scope="col" className="w-14 px-3 pb-2 text-left font-normal">
              #
            </th>
            <th scope="col" className="px-3 pb-2 text-left font-normal">
              Builder
            </th>
            <th scope="col" className="px-3 pb-2 text-left font-normal">
              Modèle
            </th>
            <th scope="col" className="px-3 pb-2 text-right font-normal">
              Proj. $
            </th>
            <th scope="col" className="px-3 pb-2 text-right font-normal">
              Sortie
            </th>
            <th scope="col" className="px-3 pb-2 text-right font-normal">
              Focus
            </th>
            <th scope="col" className="px-3 pb-2 text-right font-normal">
              Sessions
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const isYou = row.handle === you
            return (
              <tr
                key={row.handle}
                className={cn(
                  "group text-sm transition-colors",
                  isYou
                    ? "[&>td]:border-y [&>td]:border-claude/30 [&>td]:bg-claude/[0.07]"
                    : "[&>td]:bg-raised/60 hover:[&>td]:bg-raised-2",
                  "[&>td:first-child]:rounded-l-lg [&>td:last-child]:rounded-r-lg",
                  isYou && "[&>td:first-child]:border-l [&>td:last-child]:border-r",
                )}
              >
                <td className="px-3 py-3 text-ink-3">
                  <span className={cn("tabular", MEDALS[row.rank] && "text-base")}>
                    {MEDALS[row.rank] ?? rankLabel(row.rank)}
                  </span>
                </td>
                <td className="px-3 py-3">
                  <BuilderCell {...row} isYou={isYou} />
                </td>
                <td className="px-3 py-3 text-ink-2">{row.model}</td>
                <td className="px-3 py-3 text-right font-mono tabular text-claude">
                  {dollars(row.costUsd)}
                </td>
                <td className="px-3 py-3 text-right font-mono tabular text-ink">
                  {tokens(row.outputTokens)}
                </td>
                <td className="px-3 py-3 text-right font-mono tabular text-ink-2">
                  {duration(row.focusSeconds)}
                </td>
                <td className="px-3 py-3 text-right font-mono tabular text-ink-2">
                  {row.sessions}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
