import { Link, useLocation } from "react-router"

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

        <a
          href="https://github.com/MakFly/perch"
          target="_blank"
          rel="noreferrer"
          className="ml-auto text-sm text-ink-3 transition-colors hover:text-ink-2"
        >
          Télécharger
        </a>
      </div>
    </header>
  )
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
