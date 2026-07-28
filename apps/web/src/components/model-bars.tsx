import type { ModelSplit } from "@/lib/api"
import { dollarsIn, tokens } from "@/lib/format"
import { agentColour } from "@/lib/you"
import { cn } from "@/lib/utils"

/**
 * Cost per model, and what each one actually produced.
 *
 * Two lists rather than one chart: the reference shows the same split twice — once by
 * money, once by volume — because they rank differently. A model that is cheap per token
 * can still top the bill, and that inversion is the interesting part.
 */
export function ModelCostList({ split }: { split: ModelSplit[] }) {
  const peak = split.reduce((max, row) => Math.max(max, row.costUsd), 0)
  const dollars = dollarsIn(split.map((row) => row.costUsd))

  return (
    <ul className="flex flex-col">
      {split.map((row) => (
        <li key={row.model} className="relative flex items-center gap-3 px-4 py-2.5">
          <span
            className="absolute inset-y-0 left-0 rounded-r-sm bg-claude/[0.09]"
            style={{ width: peak > 0 ? `${Math.max(2, (row.costUsd / peak) * 100)}%` : "0%" }}
            aria-hidden
          />
          <ModelDot model={row.model} />
          <span className="relative truncate text-sm text-ink-2">{row.model}</span>
          <span className="relative ml-auto font-mono text-sm tabular text-ink">
            {dollars(row.costUsd)}
          </span>
        </li>
      ))}
    </ul>
  )
}

export function ModelVolumeList({ split }: { split: ModelSplit[] }) {
  const ordered = [...split].sort((a, b) => b.outputTokens - a.outputTokens)

  return (
    <ul className="flex flex-col">
      {ordered.map((row) => (
        <li key={row.model} className="flex items-center gap-3 px-4 py-2.5">
          <ModelDot model={row.model} />
          <span className="truncate text-sm text-ink-2">{row.model}</span>
          <span className="ml-auto font-mono text-xs tabular text-ink-3">
            {tokens(row.inputTokens)} in · {tokens(row.outputTokens)} out
          </span>
        </li>
      ))}
    </ul>
  )
}

/** Colour by family, so Opus and Haiku are told apart before the label is read. */
function ModelDot({ model }: { model: string }) {
  const family = model.toLowerCase()
  const colour = family.includes("gpt")
    ? "text-active"
    : family.includes("gemini")
      ? "text-info"
      : agentColour("claude")
  return <span className={cn("relative size-2 shrink-0 rounded-[2px] bg-current", colour)} />
}
