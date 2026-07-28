import { Info } from "lucide-react"

import type { Mode } from "@/lib/api"

/**
 * Says when the numbers are generated.
 *
 * A deployment with no database still renders a full board, which is the point — but a
 * demo board that presents itself as real is a claim about people who never published
 * anything. The API reports its mode on every response; this is the UI holding up its end.
 */
export function ModeNotice({ mode }: { mode: Mode }) {
  if (mode !== "demo") return null

  return (
    <div className="mb-8 flex items-start gap-3 rounded-lg border border-warning/25 bg-warning/[0.06] px-4 py-3">
      <Info className="mt-0.5 size-4 shrink-0 text-warning" aria-hidden />
      <p className="text-sm leading-relaxed text-ink-2">
        <span className="font-medium text-ink">Données de démonstration.</span> Ce
        déploiement n'a pas de base attachée : les builders et leurs compteurs sont générés,
        et aucune publication n'est acceptée. Les vrais chiffres arrivent dès qu'une
        <code className="mx-1 rounded bg-line px-1 py-0.5 font-mono text-xs">DATABASE_URL</code>
        est configurée.
      </p>
    </div>
  )
}
