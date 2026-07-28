import { useQuery } from "@tanstack/react-query"
import { ArrowLeft } from "lucide-react"
import { useState } from "react"
import { Link, useParams } from "react-router"

import { Heatmap, type HeatmapMode } from "@/components/heatmap"
import { ModelCostList, ModelVolumeList } from "@/components/model-bars"
import { ModeNotice } from "@/components/mode-notice"
import { StatStrip, StatTile } from "@/components/stat-tile"
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar"
import { Skeleton } from "@/components/ui/skeleton"
import { fetchProfile, type ProfileRange } from "@/lib/api"
import { count, dollars, initials, tokens } from "@/lib/format"
import { cn } from "@/lib/utils"

const RANGES: { id: ProfileRange; label: string }[] = [
  { id: "24h", label: "24 dernières heures" },
  { id: "7d", label: "7 derniers jours" },
  { id: "30d", label: "30 derniers jours" },
  { id: "6m", label: "6 derniers mois" },
  { id: "1y", label: "Dernière année" },
  { id: "all", label: "Total" },
]

const HEATMAP_MODES: { id: HeatmapMode; label: string }[] = [
  { id: "daily", label: "Quotidien" },
  { id: "weekly", label: "Hebdomadaire" },
  { id: "cumulative", label: "Cumulatif" },
]

export function ProfilePage() {
  const { handle = "" } = useParams()
  const [range, setRange] = useState<ProfileRange>("30d")
  const [heatmap, setHeatmap] = useState<HeatmapMode>("daily")

  const query = useQuery({
    queryKey: ["profile", handle, range],
    queryFn: () => fetchProfile(handle, range),
    staleTime: 60_000,
    retry: false,
  })

  if (query.isError) {
    return (
      <div className="mx-auto max-w-3xl px-5 py-20 text-center">
        <h1 className="text-3xl font-semibold tracking-tight">Profil introuvable</h1>
        <p className="mt-3 text-sm text-ink-3">
          Personne ne publie sous <span className="font-mono text-ink-2">@{handle}</span>, ou
          ce profil n'est pas public.
        </p>
        <Link
          to="/"
          className="mt-8 inline-flex items-center gap-2 text-sm text-ink-2 underline-offset-4 hover:underline"
        >
          <ArrowLeft className="size-4" aria-hidden /> Retour au classement
        </Link>
      </div>
    )
  }

  const profile = query.data

  return (
    // Wide enough for a year of the heatmap without a scrollbar: 53 columns at a 14px
    // pitch is 742px, and `max-w-3xl` left 688px — so the most recent weeks, which are the
    // ones anyone looks at, were the ones scrolled off the right edge.
    <div className="mx-auto max-w-4xl px-5 py-12">
      <Link
        to="/"
        className="inline-flex items-center gap-2 text-sm text-ink-3 underline-offset-4 transition-colors hover:text-ink-2 hover:underline"
      >
        <ArrowLeft className="size-4" aria-hidden /> Classement
      </Link>

      <header className="mt-10 flex flex-col items-center text-center">
        <Avatar className="size-20 border border-line">
          {profile?.builder.avatarUrl ? <AvatarImage src={profile.builder.avatarUrl} alt="" /> : null}
          <AvatarFallback className="bg-raised-2 text-xl font-medium text-ink-2">
            {profile ? initials(profile.builder.displayName) : "…"}
          </AvatarFallback>
        </Avatar>

        <h1 className="mt-5 text-3xl font-semibold tracking-tight">
          {profile?.builder.displayName ?? <Skeleton className="h-8 w-40 bg-raised" />}
        </h1>

        <div className="mt-2 flex items-center gap-2 text-sm text-ink-3">
          <span className="font-mono">@{handle}</span>
          {profile ? (
            <>
              <span aria-hidden>·</span>
              <span className="rounded-md border border-line bg-raised-2 px-1.5 py-0.5 text-xs text-ink-2">
                {profile.builder.visibility === "public" ? "Public" : "Privé"}
              </span>
              {profile.builder.team ? (
                <span className="rounded-md border border-line bg-raised-2 px-1.5 py-0.5 text-xs text-ink-2">
                  {profile.builder.team}
                </span>
              ) : null}
              {profile.rank?.position ? (
                <span className="rounded-md border border-claude/30 bg-claude/[0.08] px-1.5 py-0.5 text-xs text-claude">
                  #{profile.rank.position} cette semaine
                </span>
              ) : null}
            </>
          ) : null}
        </div>
      </header>

      <nav className="mt-9 flex flex-wrap justify-center gap-1">
        {RANGES.map((entry) => (
          <button
            key={entry.id}
            type="button"
            onClick={() => setRange(entry.id)}
            className={cn(
              "rounded-lg px-2.5 py-1.5 text-sm transition-colors",
              range === entry.id
                ? "bg-line-strong text-ink"
                : "text-ink-3 hover:bg-line hover:text-ink-2",
            )}
          >
            {entry.label}
          </button>
        ))}
      </nav>

      <div className="mt-8">{profile ? <ModeNotice mode={profile.mode} /> : null}</div>

      {profile ? (
        <>
          <StatStrip>
            <StatTile value={tokens(profile.totals.tokens)} label={`Jetons · ${labelOf(range)}`} />
            <StatTile
              value={dollars(profile.totals.costUsd)}
              label="Montant projeté"
              accent="claude"
            />
            <StatTile value={count(profile.totals.activeDays)} label="Jours actifs" />
            <StatTile
              value={`${count(profile.totals.longestStreakDays)} j`}
              label="Plus longue série"
              accent="active"
            />
          </StatStrip>

          <section className="mt-10 rounded-xl border border-line bg-raised/60 p-5">
            <div className="mb-5 flex flex-wrap items-center gap-3">
              <h2 className="text-sm font-medium text-ink">Activité des jetons</h2>
              <div className="ml-auto flex gap-1">
                {HEATMAP_MODES.map((entry) => (
                  <button
                    key={entry.id}
                    type="button"
                    onClick={() => setHeatmap(entry.id)}
                    className={cn(
                      "rounded-md px-2 py-1 text-xs transition-colors",
                      heatmap === entry.id
                        ? "bg-line-strong text-ink"
                        : "text-ink-3 hover:bg-line hover:text-ink-2",
                    )}
                  >
                    {entry.label}
                  </button>
                ))}
              </div>
            </div>
            <Heatmap days={profile.activity} mode={heatmap} />
          </section>

          <div className="mt-6 grid gap-6 sm:grid-cols-2">
            <section className="rounded-xl border border-line bg-raised/60 py-3">
              <h2 className="mb-2 px-4 text-sm font-medium text-ink">Coût par modèle</h2>
              {profile.byModel.length > 0 ? (
                <ModelCostList split={profile.byModel} />
              ) : (
                <EmptySplit />
              )}
            </section>

            <section className="rounded-xl border border-line bg-raised/60 py-3">
              <h2 className="mb-2 px-4 text-sm font-medium text-ink">Modèles les plus utilisés</h2>
              {profile.byModel.length > 0 ? (
                <ModelVolumeList split={profile.byModel} />
              ) : (
                <EmptySplit />
              )}
            </section>
          </div>
        </>
      ) : (
        <div className="flex flex-col gap-6">
          <Skeleton className="h-28 w-full rounded-xl bg-raised" />
          <Skeleton className="h-48 w-full rounded-xl bg-raised" />
        </div>
      )}
    </div>
  )
}

function EmptySplit() {
  return <p className="px-4 py-6 text-sm text-ink-3">Rien sur cette période.</p>
}

function labelOf(range: ProfileRange): string {
  return RANGES.find((entry) => entry.id === range)?.label ?? ""
}
