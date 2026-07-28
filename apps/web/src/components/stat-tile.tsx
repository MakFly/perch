import { cn } from "@/lib/utils"

interface Props {
  value: string
  label: string
  accent?: "ink" | "claude" | "info" | "active"
  className?: string
}

const ACCENTS = {
  ink: "text-ink",
  claude: "text-claude",
  info: "text-info",
  active: "text-active",
} as const

export function StatTile({ value, label, accent = "ink", className }: Props) {
  return (
    <div className={cn("flex flex-col gap-1 px-5 py-5", className)}>
      <span className={cn("text-2xl font-semibold tracking-tight tabular", ACCENTS[accent])}>
        {value}
      </span>
      <span className="text-xs text-ink-3">{label}</span>
    </div>
  )
}

/** The four tiles sit in one bordered strip, divided rather than boxed. */
export function StatStrip({ children }: { children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-2 divide-line rounded-xl border border-line bg-raised/60 sm:grid-cols-4 sm:divide-x [&>*:nth-child(-n+2)]:border-b [&>*:nth-child(-n+2)]:border-line sm:[&>*]:border-b-0!">
      {children}
    </div>
  )
}
