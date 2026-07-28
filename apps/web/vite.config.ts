import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "./src") },
  },
  server: {
    // `bun run dev` in apps/api serves the app at `/v1`; Vercel serves it at `/api/v1`.
    // The prefix is stripped here so the browser asks for the same path in both, and the
    // site never has a code path that only production exercises.
    proxy: {
      "/api": {
        target: process.env.PERCH_API ?? "http://localhost:8787",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
})
