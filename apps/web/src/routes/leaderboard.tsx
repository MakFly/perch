import { useQuery } from "@tanstack/react-query"
import { ChevronLeft, ChevronRight } from "lucide-react"
import { useState } from "react"
import { useLocation } from "react-router"

import { GuildTable } from "@/components/guild-table"
import { LeaderboardTable } from "@/components/leaderboard-table"
import { ModeNotice } from "@/components/mode-notice"
import { Skeleton } from "@/components/ui/skeleton"
import { fetchLeaderboard, type Board } from "@/lib/api"
import { count, dollars, tokens } from "@/lib/format"
import { cn } from "@/lib/utils"
import { resolveYou } from "@/lib/you"

const BOARDS: { id: Board; label: string }[] = [
  { id: "week", label: "Cette semaine" },
  { id: "month", label: "Ce mois" },
  { id: "agents", label: "Agents IA" },
  { id: "guilds", label: "Guildes" },
]

export function LeaderboardPage() {
  const { search } = useLocation()
  const [you] = useState(() => resolveYou(search))
  const [board, setBoard] = useState<Board>("agents")
  const [offset, setOffset] = useState(0)

  const query = useQuery({
    queryKey: ["leaderboard", board, offset, you],
    queryFn: () => fetchLeaderboard(board, offset, you),
    staleTime: 60_000,
  })

  return (
    <div className="mx-auto max-w-5xl px-5 py-14">
      <h1 className="display-title">Classement.</h1>

      <div className="mt-9 flex flex-wrap items-center gap-3">
        <nav className="flex flex-wrap items-center gap-1">
          {BOARDS.map((entry) => (
            <button
              key={entry.id}
              type="button"
              onClick={() => {
                setBoard(entry.id)
                setOffset(0)
              }}
              className={cn(
                "rounded-lg px-3 py-1.5 text-sm transition-colors",
                board === entry.id
                  ? "bg-line-strong text-ink"
                  : "text-ink-3 hover:bg-line hover:text-ink-2",
              )}
            >
              {entry.label}
            </button>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-1">
          <StepButton
            label="Période précédente"
            onClick={() => setOffset((value) => value + 1)}
          >
            <ChevronLeft className="size-4" aria-hidden />
          </StepButton>
          <span className="min-w-44 text-center text-sm text-ink-2">
            {query.data?.period.label ?? "…"}
          </span>
          <StepButton
            label="Période suivante"
            disabled={offset === 0}
            onClick={() => setOffset((value) => Math.max(0, value - 1))}
          >
            <ChevronRight className="size-4" aria-hidden />
          </StepButton>
        </div>
      </div>

      <HowItWorks />

      {query.data ? <ModeNotice mode={query.data.mode} /> : null}

      {query.isPending ? <BoardSkeleton /> : null}

      {query.isError ? (
        <p className="rounded-xl border border-danger/25 bg-danger/[0.06] px-4 py-6 text-sm text-ink-2">
          Le classement n'a pas répondu. Réessaie dans un instant — rien n'est perdu, les
          compteurs restent sur ta machine.
        </p>
      ) : null}

      {query.data ? (
        board === "guilds" ? (
          <GuildTable guilds={query.data.guilds} />
        ) : query.data.rows.length === 0 ? (
          <EmptyBoard />
        ) : (
          <>
            <LeaderboardTable rows={query.data.rows} you={you} />
            <p className="mt-6 text-sm text-ink-3">
              {count(query.data.totals.builders)} builders ·{" "}
              {tokens(query.data.totals.outputTokens)} jetons de sortie ·{" "}
              {dollars(query.data.totals.costUsd)} projetés sur la période
            </p>
          </>
        )
      ) : null}
    </div>
  )
}

function StepButton({
  children,
  label,
  disabled = false,
  onClick,
}: {
  children: React.ReactNode
  label: string
  disabled?: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      aria-label={label}
      disabled={disabled}
      onClick={onClick}
      className="rounded-lg p-1.5 text-ink-3 transition-colors hover:bg-line hover:text-ink-2 disabled:pointer-events-none disabled:opacity-30"
    >
      {children}
    </button>
  )
}

/**
 * The paragraph that stops the board from being a mystery.
 *
 * The reference leads with it, and it earns its place: what is counted, what is not, and
 * that the dollar figure is a projection rather than a bill. Every claim here is one the
 * product actually keeps.
 */
function HowItWorks() {
  return (
    <p className="mt-8 mb-9 max-w-3xl text-sm leading-relaxed text-ink-2">
      <span className="font-medium text-ink">Comment ça marche.</span> Jetons de sortie
      hebdomadaires de tes agents de code locaux (Claude Code, Codex, Gemini, opencode,
      Cursor) lancés dans ton terminal ou ton éditeur. La sortie est le texte réellement
      généré par le modèle, inférieur au total affiché par ton outil. Les applications de
      chat et les exécutions cloud ne sont pas comptées. Les jours passés ne peuvent pas
      être rattrapés. Le <span className="font-mono text-ink">$</span> est une projection du
      coût API de ces jetons, pas ce que tu paies. On ne lit jamais tes prompts ni ton code :
      seuls des compteurs agrégés par jour et par modèle quittent ta machine.
    </p>
  )
}

function EmptyBoard() {
  return (
    <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-line px-6 py-16 text-center">
      <p className="text-sm font-medium text-ink-2">Personne n'a publié sur cette période</p>
      <p className="max-w-sm text-sm text-ink-3">
        Le classement est vide, pas cassé. Ouvre Perch, onglet{" "}
        <span className="text-ink-2">rank</span>, et choisis un pseudo pour y figurer.
      </p>
    </div>
  )
}

function BoardSkeleton() {
  return (
    <div className="flex flex-col gap-1">
      {Array.from({ length: 8 }, (_, index) => (
        <Skeleton key={index} className="h-13 w-full rounded-lg bg-raised" />
      ))}
    </div>
  )
}
