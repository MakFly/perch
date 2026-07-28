# Perch

Approve Claude Code from your MacBook's notch — and see where your tokens go.

Perch turns the notch into a control surface for Claude Code:

- **Approve or deny** a permission request without switching back to the terminal.
- **Watch** what the CLI is doing live: tool calls, active sessions, when a task ends.
- **Count** token usage per minute / hour / day / month, with cost — and compete on a
  leaderboard.

Status: **M3** — live activity, permission approvals, and token stats all work end to end.

**Target: feature parity with Vibe Island 1.0.42.** That app is the reference implementation
of this idea and it is far ahead — 26 MB of Swift, nine locales, eleven CLI integrations, an
SSH subsystem. `docs/vibeisland-teardown.md` is a static + runtime teardown of it, and the
[roadmap](#roadmap-to-parity) below is the gap turned into work items. Nothing is copied
from that bundle; it is used as a specification of the problem.

Verified on a real corpus: 2,290 transcripts / 1.3 GB index in 34s, then 0.14s for
incremental re-indexes. Totals match an independent count exactly, to the token and the
cent — which matters, because 56% of transcript usage lines are duplicates.

## Requirements

- macOS 14+ on a Mac with a notch (Perch falls back to a floating panel elsewhere)
- Swift 6 toolchain (Xcode 26+)
- Bun 1.3+ and a running Postgres container (for the leaderboard API, from M4)

## Getting started

```bash
./scripts/setup.sh                     # creates the `perch` database
./apps/mac/Scripts/make-app.sh         # builds apps/mac/build/Perch.app
open apps/mac/build/Perch.app
./scripts/install-hooks.sh ~/my-project  # wires Claude Code into Perch
./scripts/install-hooks.sh --global      # …or once, for every project
./scripts/install-hooks.sh --codex       # …and Codex, if you use it
./scripts/usage-bridge.sh                # connects your plan's quota
./scripts/install-extension.sh           # precise terminal tabs in VS Code / Cursor
./scripts/configure-kitty.sh             # …and in kitty, if you use it
```

**Restart any Claude Code session you already have open in that project** — hooks are read
when a session starts, so a running one ignores them and the notch stays empty.

**Global or project, not both.** Claude Code merges the two scopes and runs every hook it
finds, so an install in each makes one event arrive twice: two rows in the feed, and two
blocked hooks for a single permission. The installer refuses to create that overlap, names
the file that already has it, and `--force` is there for the case where you meant it.
`./scripts/install-hooks.sh --uninstall <project>` takes one back out. Perch also drops the
copies at runtime — a settings file is something several tools write to, and the panel
should not double because one of them ran.

Perch has no Dock icon and no menu bar item. Hover the notch for a summary; click anywhere
in it to open the full panel; press `esc`, click the ✕, or move the cursor away to send it
back to resting.

At rest the notch carries what is running: a sprite per agent to the left of the cutout, the
session count to its right, the cutout itself untouched between them. The strip is sized to
its content, so one agent does not reserve room for four — and with nothing running it is
exactly zero wide, and the cutout looks like the hardware again.

The count is **live sessions, not busy ones**. It counted only sessions mid-turn until it
was pointed out that this is backwards: a CLI waiting for an answer is the one you want to
see from across the room, and it was the one that disappeared. The pill turns amber when any
of them is blocked on you.

**Right-click the notch** for Settings, Check for Updates, Mute and Quit. With no Dock icon
and no menu bar item, that menu is the only way out of the app — and until it existed there
was none.

Each running agent is a card: the name Claude Code gave the session, what you last asked,
what it is doing right now, which agent and terminal it is in, and how long it has been
going.

**⌃⌥P** opens the session switcher from anywhere. Tap it and pick with ↑↓ then Enter, or
hold it and press again to cycle — releasing jumps to the selected session. Shift reverses.
Clicking a session card jumps to it too.

When Claude Code asks for permission, the notch opens with the tool, the command and three
answers: **Allow** (⌥↵), **Always**, **Deny** (⌥⌫).

> Permission prompts only happen when Claude Code would actually ask. If you run with
> `bypass permissions on`, nothing is ever asked and the notch shows activity only.

**Always** writes a rule to that project's `.claude/settings.local.json` — for example
`Bash(npm run:*)`. The rule is shown before you commit to it, and the prefix stops at the
first flag, path or shell separator so approving `npm run build && …` never grants more
than `npm run`.

## Command line

```bash
Perch --diagnose            # how Perch sees your displays and where the panel lands
Perch --status              # what the running instance has seen; pending requests; tokens
Perch --decide allow        # answer the oldest pending request (add --remember)
Perch --answer "Postgres"   # answer a pending AskUserQuestion ("a | b, c" for several)
Perch --settings            # open the settings window of the running instance
Perch --quota               # read the plan quota from Anthropic once, and say what came back
Perch --update [--install]  # check the feed, and apply a verified update
Perch --report              # a diagnostic report with nothing private in it
Perch --index               # run the usage indexer in the foreground and report totals
PERCH_DEBUG=1 perch-hook …  # narrate a hook invocation on stderr
```

## Token stats

Perch reads `~/.claude/projects/**/*.jsonl` incrementally, remembering a byte offset per
file, and aggregates per minute / hour / day / month with cost.

Two details decide whether the numbers are right:

- **Deduplication.** Transcripts repeat entries constantly — resumed sessions, sidechains,
  duplicated files. On a real machine 56% of usage lines are repeats, so every row is keyed
  on `(message.id, requestId)`. Without that, totals are inflated by more than half.
- **Cache TTL.** Cache writes are billed at 1.25x input for the 5-minute cache and 2x for
  the 1-hour one, so the two are counted separately rather than lumped together.

Only the top-level `usage` counters are read; `usage.iterations` restates the same tokens
per internal step and would double-count every response.

## Plan quota

Spend and quota are different numbers, and the one people check is the second. Claude Code
publishes it in exactly one place: the JSON it hands the statusline command on stdin, every
render. There is no other local source.

```
  statusline render ──> bridge ──> ~/.perch/cache/rate-limits.json ─┐
                                                                    ├─> freshest wins ─> panel
  Keychain credential ──> api.anthropic.com/api/oauth/usage ────────┘        │
                          (opt-in, every 5 min)                              └─> crossed 90%? one peek
```

Which is why there is a second, remote source: a statusline that is switched off publishes
nothing, and no local trick changes that. It stays off until asked for, in
Settings › Integrations — macOS asks for the Keychain item once, the token is read per
request and dropped, and nothing leaves the machine but that one call.

`./scripts/usage-bridge.sh` therefore sits in front of that command. It reads stdin once,
caches `rate_limits`, then replays the identical bytes to your original statusline — so
what you see is byte-for-byte what you saw before. The original `statusLine` object is
stored whole, padding and refresh interval included, and `--remove` puts it back verbatim.
Every write is preceded by a timestamped backup.

```bash
./scripts/usage-bridge.sh            # install
./scripts/usage-bridge.sh --status   # what is wired up, and whether quota has arrived
./scripts/usage-bridge.sh --remove   # restore the original statusline
```

The panel then shows each window — 5 h session, 7 d all models, and any per-model weekly
window the server adds — with how much is used and when it resets.

Two things the payload will teach you the hard way:

- **Two spellings are live at once.** The schema compiled into the CLI says `utilization`
  with an ISO 8601 `resets_at`; real renders send `used_percentage` with `resets_at` as a
  Unix epoch. Perch reads both, because reading one gives a confident 0%.
- **A null window is unknown, not empty.** Windows the server has nothing to say about are
  dropped rather than drawn at 0% — those are not the same claim.

## Staying out of the way

Perch silences itself — approvals included — while the screen is locked, while it is being
recorded or shared, while a Focus mode is on, and during quiet hours. That is deliberate:
a permission card opening mid-demo puts a stranger's command on a projector. Nothing is
lost by waiting, because the request still queues, the session is still held, and the notch
still marks it with a dot.

Completions are silent unless you ask for them. A chime per finished turn is how people end
up muting an app for good.

All of it is in **Settings** — the gear in the panel header, or `Perch --settings`. Quiet
scenes and hours, sounds, the filter list with a live match count, and which hooks are
installed where, read back from disk rather than from what Perch believes it did. The files
behind it stay readable: `~/.perch/quiet.json`, `admission.json`, `preferences.json` and
`sounds.json`.

## Licensing, and what it never touches

Perch has a 7-day trial and a licence key, activated in Settings. What a licence unlocks is
the leaderboard, remote hosts, the global switcher and sound packs.

What it does **not** unlock is approving, denying, or answering a question — those always
work. Perch sits between Claude Code and its permission prompt, and an expired trial, a
failed network call or a corrupt licence file that blocked that path would be worse than
shipping no licensing at all. A corrupt file starts a fresh trial rather than locking the
app, an activated copy keeps working for 30 days without reaching the server, and a test
asserts that no feature gate ever creeps onto the approval path.

## Failing open

Perch sits between Claude Code and its permission prompt, so it is built to be skippable:
if the app is not running, is killed mid-request, or takes too long, the hook exits 0
with no output and Claude Code prompts exactly as it would without Perch. A dead app
releases a waiting session in well under a second.

The handshake in `~/.perch/runtime.json` carries the owning pid, and every reader checks
that the process is still alive before dialling its port. A crash, a force-quit or an
update that swapped the bundle underneath it all leave a file pointing at a port nobody is
listening on — and waiting out that timeout is the exact stall the handshake exists to
prevent. This was found by an update test hanging for ten minutes, not by reading the code.

## Uninstalling

Two scripts, because there are two situations. Both print their plan and change nothing
unless you pass `--yes`.

```bash
./scripts/uninstall.sh                        # dry run — what would go
./scripts/uninstall.sh --yes                  # remove Perch from this Mac
./scripts/uninstall.sh --yes --keep-data      # …but keep the token history
./scripts/uninstall.sh --yes --purge-backups  # …and the backups too

./scripts/remove.sh --yes                     # the same, plus the dev-only leftovers
```

**`uninstall.sh` is the one that ships with the app.** It assumes nothing but a shell: no
repository, no `lib.sh`, no Postgres. Hooks in every settings file it can find — global,
project, Codex — the statusline bridge put back the way it was, the editor extensions, the
`kitty.conf` block, `~/.perch`, the app bundle wherever it landed, and the four
directories macOS keeps on an app's behalf and never cleans up when one is dragged to the
Trash. It edits JSON with `jq` or `python3`, whichever is on the machine, and refuses to
touch a settings file with neither rather than reaching for `sed`.

**`remove.sh` is for a clone of this repository**: it also drops the `perch` Postgres
database and the build directories, neither of which exists on a machine that installed a
DMG.

Both remove only hook entries that point at `perch-hook`, and back up every file before
rewriting it. Remote hosts are reported rather than reached into — `./scripts/remote.sh
remove <alias>` is a deliberate, separate step, because a build server is not something an
uninstaller should quietly ssh into.

## Database

Perch reuses the shared Postgres container (`infra-postgres` by default) instead of
starting its own, following the one-database-per-project convention already in place.
Override with `PERCH_PG_CONTAINER`, `PERCH_PG_DATABASE`, etc. — see `scripts/lib.sh`.

## Layout

```
apps/mac/     Swift package: Perch.app + perch-hook, no .xcodeproj
apps/mac/Resources/  en.lproj, fr.lproj — copied into the bundle by make-app.sh
apps/vscode/  the editor extension: a manifest and one JavaScript file
apps/api/     Bun + Hono + Drizzle leaderboard API (M4)
scripts/      setup.sh, install-hooks.sh, usage-bridge.sh, remote.sh, release.sh,
              uninstall.sh (ships with the app), remove.sh (dev machine)
docs/         vibeisland-teardown.md — the parity reference
```

## Privacy

Nothing leaves the machine unless you explicitly opt in to the leaderboard, and even
then only counters are sent: token totals, model, time bucket. Prompts, file paths,
project names and commands never leave your Mac.

## Roadmap to parity

Shipped (✓) versus the reference. Ordered by value per unit of effort, not by area.

### M3.5 — correctness of the core loop

- [x] **Answer `PermissionRequest` with the schema it actually expects.** The two permission
      events do not share one: `PermissionRequest` takes
      `decision: {behavior: "allow" | "deny", …}`, `PreToolUse` takes `permissionDecision`.
      Perch was sending the second for the first, so Claude Code rejected every answer and
      fell back to its own prompt — a failure that looks exactly like Perch not being
      installed. Both shapes are now pinned by tests.
- [x] **"Always" through `updatedPermissions`** rather than Perch editing
      `settings.local.json` in parallel with the process about to rewrite it.
- [x] Hold decisions for a day, like the reference, instead of expiring them after five
      minutes; quitting Perch still releases every blocked session at once.
- [x] Rest of the event surface: `SubagentStart`, `SubagentStop`, `StopFailure`, `PreCompact`
- [x] Session state machine extracted into `PerchKit` so it is testable: working / idle /
      failed / compacting, with a live subagent count
- [x] **The two scopes are exclusive, and a duplicate is dropped rather than shown.**
      Claude Code merges global and project settings and runs both, so hooks in each fire
      twice — and it was the *second* one that made the panel repeat itself. The installer
      now refuses the overlap in both directions and can undo one side
      (`--uninstall <project>`); the app recognises a copy by the payload it was handed,
      which is byte-identical because it is the same event, and answers both blocked hooks
      from one card. Settings says how many projects are doubled, since nothing on screen
      would look wrong once the copies are dropped.
- [ ] Auto-configure new agents as they appear on the machine.
- [x] **An empty panel says which of four things is wrong.** Hooks missing, hooks stripped
      by another tool, hooks present but no session calling them, or simply nothing running
      — they look identical from the notch and their fixes are opposite. It waits 90
      seconds before saying anything: a session that has done nothing in the first minute
      is not evidence, and nagging then would be wrong every morning.
- [x] **Allow all / Deny all** across a queue, offered only when there is one. "Always" is
      deliberately absent: writing a rule for requests you have not read is how a permission
      system stops meaning anything.
- [x] **Diagnostic report** — `Perch --report`, or a button in Settings. Assembled from
      scrubbed facts rather than scrubbed afterwards: home directories become `~`, project
      names become a stable hash, and no command or prompt is in it at all. Nothing to
      redact by hand before pasting it somewhere public.
- [x] **Aggregates read off the main actor.** Four SQLite queries over tens of thousands of
      rows were running on it, and the notch missed hover events while they did. A panel
      that stops responding because it is counting tokens has its priorities backwards.
      Found by the hover smoke test failing two runs in three, not by reading the code.

### M3.6 — the resting notch, and the panel

- [x] **The notch shows what is running without being hovered.** Perch used to draw nothing
      at rest, which made it invisible in the menu bar — a defensible choice, and the wrong
      one for a product that lives there. A 4×4 pixel sprite per agent sits left of the
      cutout and the session count sits right of it, in a pill so a lone numeral does not
      read as a glitch.
- [x] Sprites rather than vendor logos: at 32pt a real logo is mush, a mark made of literal
      pixels stays crisp at any backing scale, and each agent gets a different *shape* so
      two of them are told apart without relying on colour
- [x] **The strip counts live sessions, not working ones.** A session waiting for an answer
      used to vanish from the count and the glyph row — the exact session worth seeing.
- [x] **A creature per agent.** `Resources/Sprites/` ships one PNG per agent; with that
      directory absent, `AgentGlyph` falls back to pixel art drawn in Swift and nothing
      else changes. Read `Resources/Sprites/NOTICE.txt` before shipping a paid build: the
      bundled sprites are Nintendo's, used at the owner's explicit direction, and deleting
      that one directory is the whole undo.
- [x] The strip is sized to its content and animates between widths — verified on screen at
      185pt with nothing running, 243pt with one agent, 255pt with two
- [x] **The hover transition, made of one motion instead of three.** The panel grew on a
      spring while its outline popped: an `if/else` between the resting fill and the panel
      fill gave SwiftUI two different views, and two different views cannot morph — so the
      corner radii jumped in a frame and the hairline border appeared instantly. One
      persistent shape, faded by opacity, interpolates both. The panel is also clipped to
      its own shape now, so the content is revealed by the growing box instead of drawing
      outside it for the fifth of a second the two curves disagree.
- [x] **6pt of hysteresis on the hover test.** The boundary was a single line, so a hand
      resting on it crossed several times a second, each crossing starting and cancelling a
      collapse. The flicker looked like an animation problem and was a hit-test problem.

### M3.6b — the panel, redesigned around sessions

The feed answered "what just happened". The reference answers "what are my agents doing",
which is the reason to open the notch at all.

- [x] **Session cards** — status dot, project, `You: <prompt>`, the live activity line,
      agent and terminal chips, age. The tool feed moves below them under `recent`.
- [x] Terminal identity captured from the hook's own environment (`TERM_PROGRAM`,
      `ITERM_SESSION_ID`, `WEZTERM_PANE`, `KITTY_WINDOW_ID`, `TMUX_PANE`) — the payload
      never says where a session runs, and this is also the identity a jump will need
- [x] Compact quota strip in the panel header, on every tab
- [x] **Session titles, read rather than invented.** Claude Code already names its own
      sessions — it writes an `ai-title` line into the transcript, which is the name you
      see again in `claude --resume`. Perch reads that instead of spending a model call on
      a second, different name for the same work. The transcript is scanned backwards, so
      a multi-megabyte file costs a tail read, and slugs like `limit-active-sessions-10`
      are made readable.
- [ ] Click a card to jump (needs M5)
- [ ] Collapse long session lists behind "show all N sessions"

### M4 — usage the user actually cares about

- [x] Spend per minute / hour / day / month with cost, deduplicated
- [x] Cache-TTL-aware pricing (1.25x / 2x)
- [x] **Subscription quota**: 5 h session, 7 d all models, per-model weekly windows
- [x] Statusline bridge — reversible, replays stdin untouched, timestamped backups,
      `--status` and `--remove`, and reversed by `remove.sh`
- [x] Tolerant parsing of both live payload spellings
- [x] **`api.anthropic.com/api/oauth/usage` as a second source.** The statusline is the
      only *local* publisher of the quota, and it publishes nothing until it renders — so
      someone who turned their statusline off has no number at all. This reads the
      endpoint with the credential Claude Code already holds in the Keychain. Off until
      switched on, because reading another app's Keychain item is not something to do
      quietly: macOS asks, the token is used for one request and dropped, and the only
      destination is `api.anthropic.com`. The two sources are kept apart and the freshest
      one wins, so neither can blank the other.
- [x] **A threshold that reveals the notch, and used/remaining.** Nobody watches a
      percentage climb; they discover it when the next turn is refused. The peek fires once
      per crossing — never on a first sighting, or Perch would chime at every login inside
      a full window — and goes through the same quiet-scene policy as everything else. The
      word `used` in the panel header is the control: click it to read `left` instead.
- [x] **Runtime pricing refresh**, from LiteLLM's list, pruned to Anthropic's own rows and
      cached in `~/.perch` as a few hundred bytes. The compiled-in table is never removed —
      it is the offline floor, and a model with *no* price reads as $0, which people
      believe. Prices apply when a row is indexed, so a refresh changes what tomorrow
      costs and never rewrites last month.
- [ ] Leaderboard API (Bun + Hono + Drizzle + Postgres) — the `rank` tab is still a
      placeholder, and an empty third tab costs more than a missing one

### M5 — don't switch context

- [x] **Click a session card to jump.** Hover tints the terminal chip, and the tooltip says
      where the click lands before you take it.
- [x] iTerm2: the exact split pane, by session id
- [x] Terminal.app: the exact tab, by tty — the only handle it shares with the process
      inside it, which is why the hook captures one
- [x] Everything else (Ghostty, Warp, kitty, WezTerm, Alacritty, VS Code, Cursor, Windsurf,
      Zed): bring the app forward. Window-level, and the tooltip says so rather than
      implying more.
- [x] tmux: select the pane first, so you do not watch the window switch after landing
- [x] Automation entitlement and usage description in the bundle
- [x] **IDEs: an extension for precise terminal tabs.** `./scripts/install-extension.sh`
      copies it into VS Code, Cursor and Windsurf — each runs its own extension host, so
      each needs its own copy, and only editors actually present are touched. Perch opens
      `vscode://kweli.perch-jump/focus?tty=…`; the extension matches the tty against every
      terminal's shell pid and focuses that tab. Plain JavaScript, no `node_modules`, no
      packaging step: installing it is a copy, which matters for something a native app
      asks you to install.
- [x] **kitty and WezTerm through their own remote control** — more precise, and less
      fragile, than driving them with AppleScript they do not implement. WezTerm needs no
      setup; kitty refuses remote control until it is enabled, so
      `./scripts/configure-kitty.sh` adds two lines inside a marked block and `--remove`
      takes out exactly those. Homebrew's paths are added to the tool's `PATH`, because a
      GUI app does not inherit them.
- [ ] Warp: no public way to focus an existing tab from outside, so it stays window-level
- [ ] OSC 2 title marker, and the setting to stop Claude Code overwriting it
- [ ] Custom jump rules via a registered URL scheme

### M6 — answer everything, not just tool permissions

- [x] **`AskUserQuestion` cards** — option list, multi-select, a wizard across up to four
      questions, and no submit until every one is answered. Approving the *asking* of a
      question was useless: the point of the tool is the answer, and it travels back inside
      the decision's `updatedInput`, keyed by question text.
- [x] **`ExitPlanMode` card** — the plan, scrollable and selectable, approve or send back
      free-text feedback. Denying with a message is not a refusal: Claude Code reads it and
      keeps going.
- [x] The alert panel grows to fit the card — a card that scrolls to reach its own buttons
      is unanswerable
- [x] `Perch --answer "Postgres | Auth, Billing"` answers from the command line, which is
      how the path is exercised without a click
- [x] **Approve a plan as Manual / Accept edits / Bypass rather than plain allow.** Not a
      nicety — a plain allow did not work at all. `ExitPlanMode` declares
      `requiresUserInteraction()`, and Claude Code drops an `allow` carrying no
      `updatedInput` for such a tool and prompts in the terminal as if the hook had said
      nothing, so Approve looked like a dead button. The mode is the second half: an
      approval that names none leaves the session in `plan`, where the first edit comes
      back refused. It rides as `updatedPermissions: [{type: "setMode", mode, destination:
      "session"}]`, the same update Claude Code's own prompt applies. `auto` is left off
      the card because it is gated behind a check the hook cannot see and silently falls
      back to `default`.
- [ ] Allow All / Deny All across the whole queue
- [x] **Subagents as children rather than a tally.** Each carries what it was asked for —
      read from whichever key the payload used, because the spelling has moved between
      releases — and when it started, which is the question you actually have ten minutes
      into a quiet card. They close oldest-first: the events carry no id pairing a stop
      with its own start, and inventing one would be a guess presented as a fact.
- [ ] Completion-timing policy for subagents (as the root responds / after all finish /
      every completion)
- [ ] Compaction *progress*, and interrupted / needs-attention states
- [x] **The status set, limited to what a hook can prove**: working, running tool, needs
      approval, waiting for answer, waiting for input, compacting, idle, failed. "Thinking"
      is deliberately absent — nothing distinguishes a model composing a reply from one
      about to call a tool, and a label that is right half the time is worse than one that
      is coarse and always true. `ended` is absent too: a session that ends is removed, and
      a card for something that is over is a card in the way.

### M7 — usable next to background agents

- [x] **Admission filters** — nothing else matters if the panel is full of noise. A
      silenced session is dropped whole, including anything it put on screen before the
      prompt that gave it away arrived.
- [x] Presets for known background sessions (memory writers, title generators, summaries,
      agent worktrees, temp directories) — shipped **disabled**, because hiding a session
      someone wanted is the expensive mistake
- [x] Custom rules on directory or prompt, contains / starts-with, case-insensitive, with a
      live match count and persistence in `~/.perch/admission.json`
- [x] Right-click a card to silence its directory or its prompt
- [x] Block launcher apps by bundle id, for helpers with no terminal to filter on
- [x] A settings surface to review, add and remove rules without editing the file, with a
      live count of how many sessions on screen a draft rule would hide
- [x] Idle session cleanup, never → 24 h, for CLIs with no close signal

### M8 — interaction polish

- [x] **Global switcher** on ⌃⌥P: tap to open and pick with ↑↓ then Enter, or hold and
      press again to cycle and release to jump. Shift reverses. Registered through Carbon,
      which is the one way to get a global shortcut **without Accessibility permission** —
      an event tap or a global monitor would both prompt, and Perch never asks.
- [x] **Quiet scenes**: screen locked or asleep, screen recording or sharing, macOS Focus.
      These silence *everything*, approvals included — a permission card opening mid-demo
      puts a stranger's command on a projector. The request still queues, the session is
      still held, and a dot still marks it.
- [x] **Quiet hours** that cross midnight, because agents run overnight
- [x] Sounds, restrained on purpose and configurable per event — see M9
- [x] Completions stay silent unless asked for — they are the reason people mute an app
- [x] **Smart suppression** — nothing takes the screen while the terminal doing the asking
      is already in front. Taking over to tell you what is on screen is a step backwards.
- [x] **The tap half of the switcher, actually dispatched.** `SessionSwitcher` implemented
      `.arrow` / `.confirmed` / `.cancelled`, with tests, and nothing ever sent them: the
      Carbon hot key only reports press and release, so the mode this page advertised did
      not exist at runtime. A local key monitor — installed only while the switcher is
      open, so it needs no Accessibility permission — now drives ↑↓, Enter and Escape, and
      the list scrolls to keep the selection in view.
- [x] **A finished turn is visible again.** `announce(.taskComplete)` computed a decision
      that was thrown away, so "open the panel when a task finishes" only ever changed
      whether a sound played. It now reveals the notch, and posts a silent macOS
      notification when you are somewhere you could not have seen it — never during a quiet
      scene, never during quiet hours, and never for the terminal you are already looking
      at. Clicking it jumps there.
- [ ] Auto-reveal dwell timer, dismissable by outside click
- [ ] Remappable shortcuts, with modifier-held hints on every button
- [ ] Clean and Detailed layouts; display selection (main / follow focus / built-in)
- [ ] Manual notch width and height tuning

### M9 — sound, in full

- [x] **A source per event**: off, a macOS system sound, or a file you picked. Perch ships
      no audio — the OS already has a set that matches it, and a file you chose beats
      anything shipped.
- [x] Volume, and a preview on every row. Picking a sound also plays it: choosing one you
      cannot hear is guesswork.
- [x] The noisy events start at **off**, not at a tasteful default — a chime for every
      finished turn is how an app gets muted for good
- [x] `~/.perch/sounds.json` stays hand-editable: sources are tagged strings
      (`system:Glass`, `file:/Users/you/ping.aiff`) and the encoder is configured not to
      escape slashes, which a default `JSONEncoder` does
- [x] **Sound packs** — a plain folder of audio files with a `pack.json`, deliberately not
      an archive format: you can look inside one, swap a file, and hear the result, and
      Perch never unpacks anything it was handed. Importing copies it in, so a pack from
      Downloads survives Downloads being cleared. A manifest entry naming a file that is
      not there is dropped rather than becoming a silent source that looks configured, and
      a pack that covers two events leaves the other eight alone.

### M10 — beyond Claude Code

- [x] **Codex.** `./scripts/install-hooks.sh --codex` writes `~/.codex/hooks.json`.
      Codex 0.144 speaks the *same* hook vocabulary as Claude Code — same event names, same
      payload — so this is a config file and a `--source codex` flag, not a second event
      model. Third-party hooks already in the file are preserved.
- [x] Sessions carry their agent, and each gets its own chip colour, so two agents in one
      project stay apart
- [x] **Codex trust, reported.** Codex records what it will run in `config.toml` as one
      table per hook position. Settings reads that and says how many of Perch's hooks are
      approved. It deliberately does **not** write there: the hash is over a canonical form
      Codex does not document, and forging an entry in a security store to save one command
      is the wrong trade even if the guess were right.
- [ ] Gemini, Cursor, OpenCode shims

### M11 — remote

Approve a session running on a build server from the notch on your desk.

```bash
./scripts/remote.sh add build-box deploy@10.0.0.5
./scripts/remote.sh deploy build-box     # upload the hook, wire the remote's CLIs
./scripts/remote.sh connect build-box    # open the tunnel
```

- [x] **A dependency-free remote hook.** No cross-compilation, no binary to keep in step
      with the app: it is a bash script using `/dev/tcp`, falling back to `nc`. There is
      nothing to build for linux, freebsd, amd64 or arm64 because there is nothing to
      build at all.
- [x] **The Mac sends back the finished stdout**, base64-encoded, so the remote hook does
      no JSON parsing. The schema is built once, in Swift, where it is tested — and
      base64's alphabet has no quote in it, so extracting the field with `sed` cannot run
      past its own value. A greedy match over escaped JSON is not a thing to get subtly
      wrong on someone's build server; the first version of this did exactly that.
- [x] Host management, upload, remote hook installation across all twelve events, and
      removal that restores the remote's own `settings.json` from a backup
- [x] The token is re-pushed on every `connect`, because Perch's port and token change on
      every launch — a stale token is the failure you would otherwise spend an evening on
- [x] Fail-open verified: no config, no tunnel, or a wrong token each exit 0 in silence,
      including on stderr
- [x] **Docker / Podman**: `./scripts/remote.sh docker` prints a one-liner to paste inside
      the container. A container has no tunnel and Perch cannot reach into it, so the flow
      is inverted — the container reaches the Mac through `host.docker.internal`.
- [x] **When scp is blocked**: `./scripts/remote.sh manual` prints the hook for pasting by
      hand. Corporate networks block the sftp subsystem far more often than they block ssh
      itself, and `deploy` detects a file already in place and skips the upload — so the
      manual path is a detour, not a separate mode.
- [x] **Remote usage relay** — `./scripts/remote.sh usage <alias>`. When Claude is signed
      in on the server rather than on this Mac, the two accounts have different budgets, so
      the remote's quota is listed under its own alias instead of merged into yours. It
      rides the tunnel the hooks already use: one thing to connect, one thing to debug when
      it stops working. The remote's own statusline output is replayed unchanged, exactly
      as the local bridge does.

### M11.5 — settings

- [x] **A settings window**, reached from the panel's gear or `Perch --settings` — with no
      Dock icon and no menu bar item, there was no way in at all
- [x] General: quiet scenes, quiet hours with a crosses-midnight hint, sounds, completion
      behaviour
- [x] Filters: presets with their patterns spelled out, your own rules, live match count
- [x] Integrations: which hooks are installed where — read back from the files themselves —
      and whether the quota bridge is connected
- [x] **Editable switcher shortcut**, recorded by pressing it. A bare letter is refused —
      a global shortcut with no modifier swallows that key in every app on the machine.
- [x] **Notch width and height tuning**, applied live rather than at the next launch, and
      clamped so a slider can never put the panel somewhere unreachable
- [x] **Idle session cleanup**, never → 24 h. Only bites CLIs that close without saying so.
- [x] **Blocked launcher apps** by bundle id, picked from a file panel rather than typed
      from memory — for helpers that drive an agent with no terminal to filter on

### M12 — shipping

- [x] **`./scripts/release.sh`** — release build, hardened-runtime signing, notarisation,
      stapling, DMG, and a Sparkle appcast entry. Every secret comes from the environment
      (`PERCH_SIGN_IDENTITY`, `PERCH_NOTARY_PROFILE`, `PERCH_SPARKLE_KEY`) so the script is
      committable and nothing has to be edited to ship. `--check` says exactly which of
      them is missing. Without them it still produces a DMG — ad-hoc signed, and it says
      so, because an unsigned build that looks signed is discovered at the worst moment.
- [x] The inner `perch-hook` binary is signed before the bundle that contains it, or the
      outer signature seals a stale inner one
- [x] **Licensing.** A 7-day trial, key activation, seat management, deactivation to free a
      seat, and a 30-day offline grace — someone who paid should not lose the app on a
      plane. LemonSqueezy by default because it is what this category uses, behind a
      `LicenseVendor` protocol so swapping it is one conformance rather than a rewrite. No
      API token ships in the app: the key *is* the credential.
- [x] **A licence never sits between Claude Code and a permission prompt.** It gates the
      leaderboard, remote hosts, the switcher and sound packs — never approving, denying or
      answering. A corrupt licence file starts a fresh trial rather than locking the app,
      and a test asserts no gate ever creeps onto the approval path.
- [ ] **Blocked on you** — three identities and one account, none of which are code:
      `PERCH_SIGN_IDENTITY` (Developer ID), `PERCH_NOTARY_PROFILE`
      (`xcrun notarytool store-credentials`), `PERCH_DOWNLOAD_BASE` / `PERCH_FEED_URL`
      (wherever you host the DMG and the feed), and a LemonSqueezy product id.
      Then `./scripts/release.sh --notarize` is the whole release.
- [x] **The appcast key, generated here**: `./scripts/appcast-keys.sh` makes the Ed25519
      pair, writes the private half to `~/.perch/appcast-key` at mode 600, and **refuses to
      overwrite an existing one** — replacing it would lock every installed copy out of
      updates permanently. The public half is baked into the bundle by `make-app.sh`.
- [x] **Update checking with verification** — the feed is parsed, and an enclosure's
      signature is checked against the bundled key *before* its version is even compared.
      Whoever can answer an update feed can run code on every machine that installed you,
      so there is no "could not verify, proceeding" branch. With no key in the bundle,
      checking is off entirely.
- [x] Signing uses our own tool rather than Sparkle's `sign_update`, which is on almost no
      machine — same Ed25519-over-raw-bytes scheme, so the output is interchangeable
- [x] **Self-replacement.** Verify, mount, check the bundle identifier, move the old app
      aside, `ditto` the new one in, relaunch, clean up — and if the copy fails, the old app
      is put back rather than leaving a user with nothing. Verified end to end: a signed
      0.2.0 replaced a running 0.1.0 and relaunched itself; a DMG with one byte changed was
      refused and the installed app was untouched.
- [x] A beta channel — `appcast.xml` and `appcast-beta.xml` side by side, signed by the
      same key: one more file to publish, not another service to run
- [ ] Onboarding: detect installed agents and terminals, configure them, explain the restart
- [x] **Localization** — English and French, with the infrastructure for more. Keys are the
      English text, so a missing translation falls back to something readable instead of to
      a dotted identifier, and formatting happens *after* lookup so a placeholder lands
      where the translated sentence wants it.
- [ ] Opt-in diagnostics export (system info + anonymized logs)
- [ ] Memory watchdog: relaunch only when memory stays high and all sessions are idle
- [ ] Bundle integrity check

## Development

```bash
cd apps/mac
swift build
swift test
```
