import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router"

import { DOWNLOAD_URL, fetchRelease } from "@/lib/api"
import { cn } from "@/lib/utils"

const LINKS = [
  { to: "/", label: "Classement" },
  { to: "/a-propos", label: "À propos" },
]

export function SiteHeader() {
  const { pathname } = useLocation()

  return (
    <header className="sticky top-0 z-30 border-b border-line bg-surface/80 backdrop-blur-xl">
      <div className="mx-auto flex h-14 max-w-5xl items-center gap-6 px-5">
        <Link to="/" className="group flex items-center gap-2.5">
          <Notch />
          <span className="text-sm font-semibold tracking-tight">Perch</span>
        </Link>

        <nav className="flex items-center gap-1">
          {LINKS.map((link) => (
            <Link
              key={link.to}
              to={link.to}
              className={cn(
                "rounded-md px-2.5 py-1.5 text-sm transition-colors",
                pathname === link.to
                  ? "bg-line-strong text-ink"
                  : "text-ink-3 hover:text-ink-2",
              )}
            >
              {link.label}
            </Link>
          ))}
        </nav>

        <DownloadLink />
      </div>
    </header>
  )
}

/**
 * The DMG, in one click.
 *
 * The version is asked for separately and the link does not wait for it: a button that
 * appears only once a second request has answered is a button people miss. When nothing is
 * published yet the API answers 404, and saying so beats a link that downloads an error.
 */
function DownloadLink() {
  const { data, isError } = useQuery({
    queryKey: ["release"],
    queryFn: fetchRelease,
    staleTime: 30 * 60_000,
    retry: false,
  })

  if (isError) {
    return (
      <span className="ml-auto text-sm text-ink-3" title="Aucune version publiée">
        Bientôt
      </span>
    )
  }

  return (
    <a
      href={DOWNLOAD_URL}
      className="ml-auto flex items-center gap-2 rounded-md bg-ink px-3 py-1.5 text-sm font-medium text-surface transition-opacity hover:opacity-90"
    >
      Télécharger
      {data ? (
        <span className="text-xs font-normal opacity-60">
          {data.version} · {megabytes(data.sizeBytes)}
        </span>
      ) : null}
    </a>
  )
}

function megabytes(bytes: number): string {
  return `${(bytes / 1_000_000).toFixed(1).replace(".", ",")} Mo`
}

/** The product's own mark: the cutout, with something perched to the left of it. */
function Notch() {
  return (
    <span className="relative flex h-4 w-9 items-center justify-center rounded-b-[6px] bg-ink/90">
      <span className="absolute left-1 h-1.5 w-1.5 rounded-[1px] bg-surface" />
      <span className="absolute right-1 h-1 w-2.5 rounded-full bg-surface" />
    </span>
  )
}
