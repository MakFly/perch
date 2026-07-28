import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { BrowserRouter, Link, Route, Routes } from "react-router"

import { SiteHeader } from "@/components/site-header"
import { AboutPage } from "@/routes/about"
import { LeaderboardPage } from "@/routes/leaderboard"
import { ProfilePage } from "@/routes/profile"

const client = new QueryClient({
  defaultOptions: {
    queries: {
      // The board moves once a session ends, not once a second. Refetching on every window
      // focus would make the ranking twitch while someone reads it.
      refetchOnWindowFocus: false,
      staleTime: 60_000,
      retry: 1,
    },
  },
})

export default function App() {
  return (
    <QueryClientProvider client={client}>
      <BrowserRouter>
        <SiteHeader />
        <main>
          <Routes>
            <Route path="/" element={<LeaderboardPage />} />
            <Route path="/u/:handle" element={<ProfilePage />} />
            <Route path="/a-propos" element={<AboutPage />} />
            <Route path="*" element={<NotFound />} />
          </Routes>
        </main>
        <Footer />
      </BrowserRouter>
    </QueryClientProvider>
  )
}

function NotFound() {
  return (
    <div className="mx-auto max-w-2xl px-5 py-24 text-center">
      <h1 className="display-title">404.</h1>
      <p className="mt-4 text-sm text-ink-3">Cette page n'existe pas.</p>
      <Link
        to="/"
        className="mt-8 inline-block text-sm text-ink-2 underline-offset-4 hover:underline"
      >
        ← Retour au classement
      </Link>
    </div>
  )
}

function Footer() {
  return (
    <footer className="mt-16 border-t border-line">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2 px-5 py-8 text-xs text-ink-3">
        <span>Perch — approuve Claude Code depuis l'encoche de ton MacBook.</span>
        <Link to="/a-propos" className="underline-offset-4 hover:text-ink-2 hover:underline">
          Ce qui est compté
        </Link>
        <span className="ml-auto font-mono">Departure Mono © Helena Zhang, SIL OFL 1.1</span>
      </div>
    </footer>
  )
}
