import { Link } from "react-router"

import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar"
import { initials } from "@/lib/format"
import { agentColour } from "@/lib/you"
import { cn } from "@/lib/utils"

interface Props {
  handle: string
  displayName: string
  avatarUrl: string | null
  team: string | null
  agent: string
  isYou?: boolean
  size?: "sm" | "lg"
}

export function BuilderCell({
  handle,
  displayName,
  avatarUrl,
  team,
  agent,
  isYou = false,
  size = "sm",
}: Props) {
  return (
    <div className="flex min-w-0 items-center gap-3">
      <Avatar className={cn("shrink-0 border border-line", size === "lg" ? "size-10" : "size-7")}>
        {avatarUrl ? <AvatarImage src={avatarUrl} alt="" /> : null}
        <AvatarFallback className="bg-raised-2 text-[10px] font-medium text-ink-2">
          {initials(displayName)}
        </AvatarFallback>
      </Avatar>

      <Link
        to={`/u/${handle}`}
        className="truncate font-medium text-ink underline-offset-4 hover:underline"
      >
        {displayName}
      </Link>

      {team ? <TeamBadge team={team} agent={agent} /> : null}

      {isYou ? <span className="shrink-0 text-xs text-ink-3">(toi)</span> : null}
    </div>
  )
}

/**
 * The guild chip.
 *
 * Its dot is coloured by the agent rather than by the team, so two people on the same team
 * running different CLIs stay distinguishable — the same reason the panel gives each agent
 * its own chip colour.
 */
function TeamBadge({ team, agent }: { team: string; agent: string }) {
  return (
    <span className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-line bg-raised-2 px-1.5 py-0.5 text-[11px] text-ink-2">
      <span className={cn("size-1.5 rounded-[1px] bg-current", agentColour(agent))} />
      <span className="max-w-28 truncate">{team}</span>
    </span>
  )
}
