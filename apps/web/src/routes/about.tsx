import { Link } from "react-router"

/**
 * What is counted, what leaves the machine, and what does not.
 *
 * A public leaderboard built on someone's coding session has to answer that on its own
 * page rather than in a footnote — the whole product is worth less if a reader has to
 * guess.
 */
export function AboutPage() {
  return (
    <div className="mx-auto max-w-2xl px-5 py-16">
      <h1 className="display-title">À propos.</h1>

      <div className="mt-10 flex flex-col gap-8 text-sm leading-relaxed text-ink-2">
        <section>
          <h2 className="mb-2 text-base font-medium text-ink">Ce que Perch compte</h2>
          <p>
            Perch lit les transcriptions que tes agents de code laissent sur ta machine —{" "}
            <span className="font-mono text-ink-3">~/.claude/projects/**/*.jsonl</span> et
            leurs équivalents pour Codex, Gemini, Cursor et opencode — et en agrège les
            compteurs de jetons par minute, heure, jour et mois. Chaque ligne est
            dédupliquée sur <span className="font-mono text-ink-3">(message.id, requestId)</span> :
            sur une vraie machine, 56 % des lignes d'usage sont des répétitions, et sans ça
            les totaux sont gonflés de plus de moitié.
          </p>
        </section>

        <section>
          <h2 className="mb-2 text-base font-medium text-ink">Ce qui quitte ta machine</h2>
          <p>
            Rien, sauf si tu actives le classement. Et dans ce cas, uniquement des compteurs
            agrégés : des jetons, un modèle, un jour. Jamais un prompt, jamais un chemin,
            jamais un nom de projet, jamais une commande.
          </p>
        </section>

        <section>
          <h2 className="mb-2 text-base font-medium text-ink">Le montant en dollars</h2>
          <p>
            C'est une projection du coût API de ces jetons aux tarifs publics, pas ce que tu
            paies. Un abonnement ne facture pas au jeton — la colonne existe pour comparer
            des volumes sur une échelle que tout le monde lit d'un coup d'œil.
          </p>
        </section>

        <section>
          <h2 className="mb-2 text-base font-medium text-ink">Y figurer</h2>
          <p>
            Ouvre Perch, onglet <span className="text-ink">rank</span>, choisis un pseudo. Le
            classement est le seul endroit du produit où une identité est nécessaire, et
            approuver ou refuser une permission n'en dépend jamais.
          </p>
        </section>
      </div>

      <Link
        to="/"
        className="mt-12 inline-block text-sm text-ink-3 underline-offset-4 hover:text-ink-2 hover:underline"
      >
        ← Retour au classement
      </Link>
    </div>
  )
}
