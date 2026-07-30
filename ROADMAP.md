# Roadmap

What is shipped (✓) and what is not. Ordered by value per unit of effort, not by area.

### M3.5 — correctness of the core loop

- [x] **Answer `PermissionRequest` with the schema it actually expects.** The two permission
      events do not share one: `PermissionRequest` takes
      `decision: {behavior: "allow" | "deny", …}`, `PreToolUse` takes `permissionDecision`.
      Perch was sending the second for the first, so Claude Code rejected every answer and
      fell back to its own prompt — a failure that looks exactly like Perch not being
      installed. Both shapes are now pinned by tests.
- [x] **"Always" through `updatedPermissions`** rather than Perch editing
      `settings.local.json` in parallel with the process about to rewrite it.
- [x] Hold decisions for a day rather than expiring them after five minutes; quitting
      Perch still releases every blocked session at once.
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
- [x] **A creature per agent, drawn here.** The pixel art in `AgentGlyph.swift` owes
      nothing to anyone: the shapes evoke the archetypes, the pixels are ours. An optional
      `Resources/Sprites/` overrides them with one PNG per agent for anyone who wants to —
      absent, nothing changes.
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

The feed answered "what just happened". What you actually open the notch for is "what are
my agents doing".

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

### M3.7 — the panel reads like a conversation

The reference answers "what did it say", which is the reason to open a notch instead of
switching to the terminal. This is that gap, closed.

- [x] **The last exchange, on the card.** `Transcript.lastTurn` reads the tail of the file
      and keeps what is prose: `thinking` is addressed to nobody, `tool_use` is already the
      activity line, sidechains belong to subagents, and a `user` line carrying a
      `tool_result` is not a prompt — taking one for a prompt puts a diff where the question
      belongs. Rendered with headings, bullets and fenced code, because that is what a coding
      agent writes.
- [x] **Read off the hook path.** A hook call holds the CLI that made it, so a megabyte read
      per event would be paid by the agent in the one place this app is built to be
      skippable. `TranscriptWatcher` polls instead — off the main actor, and only while the
      panel is on screen.
- [x] **Clipped and faded, not scrolled.** A scroll view inside a card inside a panel that
      scrolls takes the wheel away from the panel the moment the cursor crosses a reply.
      (`ImageRenderer` also cannot lay one out, which is how this was noticed.)
- [x] **`Writing…` / `Done`** on the exchange, because text that is not moving and an agent
      that has stopped look identical.
- [x] **Quota in the resting strip** — the two windows every account has left of the cutout,
      any per-model weekly window right of it. A quota you have to open a panel to read is a
      quota you discover when the next turn is refused.
- [x] **A count of held requests**, beside the session count. The amber pill says *that*
      something is waiting; four queued approvals and one are a different afternoon.
- [x] **The strip is measured, not estimated** — `Theme.monoWidth`, from the label the view
      actually draws. Sizing for the widest a chip could ever be reserved a third more menu
      bar than it used.
- [x] **`--render --idle`** draws the resting strip off screen, and `--status` prints the
      exchange each card would draw. The strip needs Screen Recording to photograph and
      Accessibility to open — the two permissions this app never asks for.
- [x] **The jump arrow is on the chip** before the cursor arrives, not on hover.
- [x] **Mute and settings on the resting strip.** They cannot be buttons: the canvas ignores
      the mouse while idle, which is what stops Perch's window answering for every click in
      the top of the screen and lets the menu bar underneath keep working. The controller
      already samples the cursor for hover, so it routes the click against `IdleStrip`'s
      rectangles instead — and that arithmetic is in `PerchKit`, tested, because the picture
      and the target are computed in two different files and a gear drawn 5pt from where it
      can be clicked is worse than no gear.
- [ ] A reply preview line above the block, for the collapsed card
- [ ] Per-session jump shortcut

### M4 — usage the user actually cares about

- [x] Spend per minute / hour / day / month with cost, deduplicated
- [x] Cache-TTL-aware pricing (1.25x / 2x)
- [x] **Subscription quota**: 5 h session, 7 d all models, per-model weekly windows
- [x] Statusline bridge — reversible, replays stdin untouched, timestamped backups,
      `--status` and `--remove`, and reversed by `remove.sh`
- [x] Tolerant parsing of both live payload spellings
- [ ] ~~`api.anthropic.com/api/oauth/usage` as a second source.~~ **Dropped.** It worked,
      and it was opt-in — but it only worked by reading another app's credential out of the
      login Keychain, which puts a password dialog on screen and makes Perch a program that
      handles a secret. No quota number is worth that. The statusline bridge stays the only
      source; someone with their statusline off has no quota, and that is the honest answer.
      Perch links no `Security` framework and holds no credential path.
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
- [x] **Nothing ever sits between Claude Code and a permission prompt.** Approving, denying
      and answering always work, and a test asserts no gate ever creeps onto that path.
- [ ] **Blocked on you** — three identities, none of which are code: `PERCH_SIGN_IDENTITY`
      (Developer ID), `PERCH_NOTARY_PROFILE` (`xcrun notarytool store-credentials`), and
      `PERCH_DOWNLOAD_BASE` / `PERCH_FEED_URL` (wherever you host the DMG and the feed).
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

