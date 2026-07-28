# Perch

Approve Claude Code from your MacBook's notch — and see where your tokens go.

- **Approve or deny** a permission request without leaving what you are doing.
- **Watch** live sessions: tool calls, subagents, when a turn ends.
- **Count** tokens per minute / hour / day / month, with cost and plan quota.

Status: **M3** — activity, approvals and token stats work end to end. Claude Code and Codex
are supported; the leaderboard API is the last piece in flight.

## Install

**Télécharger** on the site hands you the latest DMG — universal, macOS 14+. It goes
through `GET /v1/download` on the API, which resolves the newest release and redirects to a
signed URL, so the repository can stay private and the link still works for anyone. From a
clone, [Releases](../../releases) is the same file.

Drag Perch to Applications, then clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Perch.app
```

That step is needed because the build is ad-hoc signed rather than notarised: macOS refuses
a downloaded app it cannot check with *"Perch is damaged"*, which reads like a corrupt
download and is not one. Releases are built by `.github/workflows/dmg.yml` on every `v*` tag,
and can be built on demand from the Actions tab.

Launch it and the first screen finds your CLIs and wires them up — the bundle carries the
`scripts/` it needs, so a DMG install needs no clone. Then restart any Claude Code session
already open.

## Building it yourself

- macOS 14+ (Perch falls back to a floating panel on Macs with no notch)
- Swift 6 toolchain (Xcode 26+)
- Bun 1.3+ and a Postgres container — only for the leaderboard API

```bash
./scripts/setup.sh                       # creates the `perch` database
./apps/mac/Scripts/make-app.sh           # builds apps/mac/build/Perch.app
open apps/mac/build/Perch.app
./scripts/install-hooks.sh ~/my-project  # wires Claude Code into Perch
./scripts/install-hooks.sh --global      # …or once, for every project
./scripts/install-hooks.sh --codex       # …and Codex, if you use it
./scripts/usage-bridge.sh                # connects your plan's quota
./scripts/install-extension.sh           # precise terminal tabs in VS Code / Cursor
./scripts/configure-kitty.sh             # …and in kitty, if you use it
```

**Restart any Claude Code session already open** — hooks are read at session start.

**Global or project, not both.** Claude Code runs hooks from both scopes, so installing in
each makes every event arrive twice. The installer refuses the overlap; `--force` overrides,
`--uninstall <project>` takes one back out.

## Using it

Perch has no Dock icon and no menu bar item. Hover the notch for a summary, click to open the
panel, `esc` or move away to dismiss. **Right-click** for Settings, Updates, Mute and Quit.

At rest the notch shows a sprite per running agent and a live session count — live, not busy,
because a CLI waiting on you is the one worth seeing. The pill turns amber when one of them is
*blocked* — a held request or a question, something you can answer from the notch. A turn that
simply ended says `Done` and stays quiet: every turn ends, and an alert that is always on is
not an alert.
That is the whole strip: what is running, and how many. Everything else — the quota, the
controls — is one hover away, and with nothing running the strip is exactly zero wide, so a Mac
doing nothing looks like a Mac doing nothing.

A sprite plays only while that agent is working, and while it works it fights: half again the
frame rate, a hop off the floor on its own beat, every other one turned around to face the last,
and — for the one with a mouth for it — a breath of fire between hops. A session that has
stopped holds its first frame and dims.

Sprites are optional by construction. `AgentGlyph` draws its own 10×10 pixel art — a fire
lizard, a shelled swimmer, a seed-carrier, owing nobody anything — and that is what the
repository ships. Drop `agent-claude.png`, `agent-codex.png` or `agent-gemini.png` into
`apps/mac/Resources/Sprites/` and it plays those instead: one row of square frames, so the
frame count is the width divided by the height, at 10 frames a second.

A turn ending flashes one line beside the cutout for two seconds and takes it back on its own —
which session, and what it was doing. A session that ended badly and a quota window crossing
your line arrive the same way. Reaching for a flash turns it into the summary.

Each session is a card: name, last prompt, current activity, agent and terminal, age. Click it
to jump to that terminal (exact pane in iTerm2, Terminal.app, kitty, WezTerm and VS Code-family
editors; window-level elsewhere). **⌃⌥P** opens the session switcher from anywhere.

Permission requests open the notch with **Allow** (⌥↵), **Always** and **Deny** (⌥⌫).
`AskUserQuestion` and `ExitPlanMode` get their own cards — plan approval also sets the mode
(Manual / Accept edits / Bypass). "Always" writes a scoped rule to that project's
`.claude/settings.local.json`, shown before you commit to it.

> Prompts only appear when Claude Code would actually ask. Under `bypass permissions on`,
> nothing is asked and the notch shows activity only.

## Command line

```bash
Perch --diagnose            # how Perch sees your displays, and where the panel lands
Perch --status              # sessions seen, pending requests, tokens
Perch --decide allow        # answer the oldest pending request (add --remember)
Perch --answer "Postgres"   # answer an AskUserQuestion ("a | b, c" for several)
Perch --quota               # read the plan quota from Anthropic once
Perch --update [--install]  # check the feed, apply a verified update
Perch --report              # a diagnostic report with nothing private in it
Perch --index               # run the usage indexer in the foreground
```

## Token stats and quota

Perch reads `~/.claude/projects/**/*.jsonl` incrementally (byte offset per file) and
aggregates with cost. Two details decide whether the numbers are right: rows are keyed on
`(message.id, requestId)` because 56% of usage lines are duplicates, and cache writes are
priced per TTL (1.25x for 5 min, 2x for 1 h). Verified against an independent count on 2,290
transcripts: exact, to the token and the cent.

Quota is a different number, published in exactly one local place — the JSON Claude Code
hands the statusline. `usage-bridge.sh` sits in front of that command, caches `rate_limits`,
and replays your original statusline byte for byte (`--remove` restores it verbatim).
Optionally, Settings › Integrations enables a second source, `api.anthropic.com/api/oauth/usage`,
read with the credential already in the Keychain. Freshest source wins.

## Staying out of the way

Perch silences itself — approvals included — while the screen is locked, recorded or shared,
during Focus modes and quiet hours. Nothing is lost: the request queues, the session stays
held, a dot marks it. Completions are silent unless you ask for them.

Everything is in **Settings** (panel gear, or `Perch --settings`), backed by readable files:
`~/.perch/quiet.json`, `admission.json`, `preferences.json`, `sounds.json`.

## Failing open

If Perch is not running, is killed mid-request, or takes too long, the hook exits 0 with no
output and Claude Code prompts exactly as it would without Perch. `~/.perch/runtime.json`
carries the owning pid so readers never dial a port nobody is listening on. Nothing ever sits
between Claude Code and its permission prompt — approving, denying and answering always work.

## Remote

Approve a session running on a build server from the notch on your desk. The remote hook is a
dependency-free bash script (`/dev/tcp`, falling back to `nc`) — nothing to cross-compile.

```bash
./scripts/remote.sh add build-box deploy@10.0.0.5
./scripts/remote.sh deploy build-box     # upload the hook, wire the remote's CLIs
./scripts/remote.sh connect build-box    # open the tunnel
./scripts/remote.sh usage build-box      # relay that host's quota under its own alias
./scripts/remote.sh docker               # a one-liner to paste inside a container
```

## Uninstalling

Both scripts print their plan and change nothing without `--yes`.

```bash
./scripts/uninstall.sh --yes                  # remove Perch from this Mac
./scripts/uninstall.sh --yes --keep-data      # …but keep the token history
./scripts/remove.sh --yes                     # the same, plus dev-only leftovers
```

`uninstall.sh` ships with the app and assumes nothing but a shell. Both remove only hook
entries pointing at `perch-hook`, and back up every file before rewriting it. Remote hosts are
reported rather than reached into.

## Privacy

Nothing leaves the machine unless you opt in to the leaderboard, and then only counters:
token totals, model, time bucket. Prompts, file paths, project names and commands never do.

## Layout

```
apps/mac/     Swift package: Perch.app + perch-hook, no .xcodeproj
apps/web/     the site and the public leaderboard: React + Vite
apps/api/     Bun + Hono + Drizzle leaderboard API
apps/vscode/  the editor extension: a manifest and one JavaScript file
scripts/      setup, install-hooks, usage-bridge, remote, release,
              uninstall.sh (ships with the app), remove.sh (dev machine)
ROADMAP.md    what is shipped and what is not
```

## Development

```bash
cd apps/mac
swift build
swift test
```

## Licence

MIT — see [LICENSE](LICENSE). Departure Mono, bundled in the app, is © Helena Zhang under
the SIL Open Font License 1.1.
