import { Users } from "lucide-react"

import type { GuildRow } from "@/lib/api"
import { MEDALS, count, dollarsIn, duration, rankLabel, tokens } from "@/lib/format"
import { cn } from "@/lib/utils"

/**
 * Teams, rolled up from the individual rows.
 *
 * A builder with no team is not a guild of one — the empty state below says so rather than
 * listing everybody twice under their own name.
 */
export function GuildTable({ guilds }: { guilds: GuildRow[] }) {
  if (guilds.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-line px-6 py-16 text-center">
        <Users className="size-6 text-ink-3" aria-hidden />
        <p className="text-sm font-medium text-ink-2">Aucune guilde sur cette période</p>
        <p className="max-w-sm text-sm text-ink-3">
          Une guilde apparaît dès que deux builders publient sous la même équipe. Le nom
          d'équipe se règle dans Perch, onglet <span className="text-ink-2">rank</span>.
        </p>
      </div>
    )
  }

  const dollars = dollarsIn(guilds.map((guild) => guild.costUsd))

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] border-separate border-spacing-y-1">
        <thead>
          <tr className="text-[11px] uppercase tracking-[0.12em] text-ink-3">
            <th scope="col" className="w-14 px-3 pb-2 text-left font-normal">
              #
            </th>
            <th scope="col" className="px-3 pb-2 text-left font-normal">
              Guilde
            </th>
            <th scope="col" className="px-3 pb-2 text-right font-normal">
              Membres
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
          </tr>
        </thead>
        <tbody>
          {guilds.map((guild) => (
            <tr
              key={guild.team}
              className="text-sm [&>td]:bg-raised/60 [&>td:first-child]:rounded-l-lg [&>td:last-child]:rounded-r-lg hover:[&>td]:bg-raised-2"
            >
              <td className="px-3 py-3 text-ink-3">
                <span className={cn("tabular", MEDALS[guild.rank] && "text-base")}>
                  {MEDALS[guild.rank] ?? rankLabel(guild.rank)}
                </span>
              </td>
              <td className="px-3 py-3 font-medium text-ink">{guild.team}</td>
              <td className="px-3 py-3 text-right font-mono tabular text-ink-2">
                {count(guild.members)}
              </td>
              <td className="px-3 py-3 text-right font-mono tabular text-claude">
                {dollars(guild.costUsd)}
              </td>
              <td className="px-3 py-3 text-right font-mono tabular text-ink">
                {tokens(guild.outputTokens)}
              </td>
              <td className="px-3 py-3 text-right font-mono tabular text-ink-2">
                {duration(guild.focusSeconds)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
