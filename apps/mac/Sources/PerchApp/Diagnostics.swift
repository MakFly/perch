import AppKit
import ImageIO
import PerchKit
import SwiftUI

/// `Perch --diagnose` prints what Perch thinks the screen looks like, then exits.
///
/// Notch geometry is the one thing that cannot be unit-tested — it depends on the actual
/// display — so this is how we verify placement on any machine, including ones where
/// screen recording is not permitted.
enum Diagnostics {
    static func run() {
        // The panel silently falls back to SF Mono when the bundled face fails to
        // register, and the difference is not obvious enough to notice by eye — which is
        // exactly the kind of thing that ships broken.
        print("font             \(Theme.resolvedTypefaceName)")

        for (index, screen) in NSScreen.screens.enumerated() {
            let geometry = NotchGeometry.detect(on: screen)
            let name = screen.localizedName
            print("screen[\(index)] \(name)")
            print("  frame            \(format(screen.frame))")
            print("  backingScale     \(screen.backingScaleFactor)")
            print("  safeAreaInsets   top=\(screen.safeAreaInsets.top)")
            print("  auxTopLeft       \(screen.auxiliaryTopLeftArea.map(format) ?? "nil")")
            print("  auxTopRight      \(screen.auxiliaryTopRightArea.map(format) ?? "nil")")
            print("  hasNotch         \(geometry.hasNotch)")
            print("  notchSize        \(format(geometry.size))")
            print("  notchRect        \(format(geometry.rect))")
            // The window's actual frame — set once, never resized. Everything below is
            // drawn inside it, so a panel that does not fit here is a panel that clips.
            let canvas = NotchState.canvas(notch: geometry.size)
            print("  canvas           \(format(canvas))")
            print("  canvasFrame      \(format(geometry.panelFrame(for: canvas, on: screen)))")
            for state in NotchState.allCases {
                let size = state.size(notch: geometry.size)
                let fits = size.width <= canvas.width && size.height <= canvas.height
                print("  panel[\(label(state))]  \(format(size))  \(fits ? "fits" : "CLIPS")")
            }
        }
    }

    /// Asks the already-running instance what it has seen. Exits non-zero when there is
    /// nothing listening, so scripts can tell "not running" from "running but idle".
    static func status() -> Int32 {
        send(event: Wire.statusEvent) { runtime, status in
            print("pid \(runtime.pid), port \(runtime.port)")
            print(status ?? "(no status)")
        }
    }

    /// `Perch --index` runs the usage indexer in the foreground and reports what it read.
    /// Indexing is otherwise invisible, so this is how a wrong root path or an unreadable
    /// transcript gets diagnosed.
    static func index() -> Int32 {
        do {
            let store = try UsageStore(path: UsageStore.defaultURL.path)
            let indexer = UsageIndexer(store: store)

            let transcripts = indexer.transcriptURLs()
            print("store       \(UsageStore.defaultURL.path)")
            // Broken down by agent: "0 files" and "0 Codex files" are different problems,
            // and this command exists to tell them apart.
            let codex = transcripts.filter { if case .codex = $0.source { true } else { false } }
            print("transcripts \(transcripts.count) files (\(codex.count) Codex)")
            // opencode keeps no transcripts at all — one SQLite store, read in place — so
            // it is reported as what it is rather than counted in the line above.
            let opencode = OpencodeUsage.defaultDatabaseURL
            let hasOpencode = FileManager.default.fileExists(atPath: opencode.path)
            print("opencode    \(hasOpencode ? opencode.path : "no database")")
            if let first = transcripts.first {
                print("first       \(first.url.path)")
            } else if !hasOpencode {
                print("nothing to index — are ~/.claude/projects and ~/.codex/sessions present?")
                return 1
            }

            let clock = ContinuousClock()
            var progress = UsageIndexer.Progress()
            let elapsed = try clock.measure {
                progress = try indexer.indexAll()
            }

            print(
                "indexed     \(progress.eventsInserted) new events from \(progress.filesScanned) files"
            )
            print("read        \(progress.bytesRead / 1_048_576) MB in \(elapsed)")

            let totals = try store.totals()
            print("--- totals ---")
            print("responses   \(totals.events)")
            print("input       \(totals.inputTokens)")
            print("output      \(totals.outputTokens)")
            print("cache read  \(totals.cacheReadTokens)")
            print("cache write \(totals.cacheWriteTokens)")
            print("cost        \(String(format: "$%.2f", totals.cost))")
            return 0
        } catch {
            print("index failed: \(error)")
            return 1
        }
    }

    /// `Perch --render <path.png>` draws the panel off screen.
    ///
    /// The one part of the UI a terminal cannot otherwise see: a screenshot of the notch
    /// needs Screen Recording and opening it needs a synthetic click, and Perch is built
    /// to ask for neither. `ImageRenderer` needs neither either.
    @MainActor
    static func render(
        _ path: String, layout: PanelLayout = .detailed, idle: Bool = false,
        phases: Bool = false, plan: Bool = false, stats: UsageStore.Agent? = nil
    ) -> Int32 {
        if plan {
            // The card with the most structure in it, and the only one whose defects are
            // all about block boundaries — which a still image shows and a test cannot.
            return write(ImageRenderer(content: PanelPreview.planScene()), to: path)
        }
        if let stats {
            // Real numbers, from this machine's index — the point of drawing this pane is
            // to see which agents it offers and what they add up to, and a fabricated one
            // would answer neither. The aggregates are read off the main actor, so the
            // loop is pumped until they land rather than rendering an empty screen.
            let usage = UsageModel()
            usage.start()
            usage.agent = stats
            RunLoop.current.run(until: .now + 2)
            return write(ImageRenderer(content: PanelPreview.statsScene(usage: usage)), to: path)
        }
        if phases {
            // Every state in its real shape, over a menu bar: the only way to see what the
            // two top corners do without Screen Recording.
            return write(ImageRenderer(content: PanelPreview.phases()), to: path)
        }
        return idle
            ? write(ImageRenderer(content: PanelPreview.idleScene()), to: path)
            : write(ImageRenderer(content: PanelPreview.scene(layout: layout)), to: path)
    }

    @MainActor
    private static func write(_ renderer: ImageRenderer<some View>, to path: String) -> Int32 {
        // Retina, so the pixel glyphs and the bitmap face are judged at the scale they
        // are actually drawn at.
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            print("render failed — no image")
            return 1
        }
        let url = URL(fileURLWithPath: path)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else {
            print("cannot write \(path)")
            return 1
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            print("cannot encode \(path)")
            return 1
        }
        print("wrote \(path)  \(image.width)×\(image.height)  font \(Theme.resolvedTypefaceName)")
        return 0
    }

    /// `Perch --tasks <session id>` prints the plan Perch would draw under that session's
    /// card, straight from disk. With no id, lists the sessions that have one — which is
    /// how you find the id in the first place.
    /// What Perch can see of Codex right now, without a running app.
    ///
    /// Codex reaches the island through the rollouts it writes rather than through hooks —
    /// the desktop app shares `~/.codex` and does not run them — which makes "why is my
    /// Codex session not on a card" a question about files rather than about events. This
    /// answers it in the same terms the panel uses.
    static func codex(activeWithin: TimeInterval = 30 * 60) -> Int32 {
        let sessions = CodexSessions.live(activeWithin: activeWithin)
        print("rollouts    \(CodexSessions.defaultRoot.path)")
        print("names       \(CodexSessions.defaultIndex.path)")
        guard !sessions.isEmpty else {
            print(
                "no Codex session has written in the last "
                    + "\(Int(activeWithin / 60)) minutes")
            return 1
        }

        print("sessions    \(sessions.count)")
        for session in sessions {
            let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            let age = Int(Date.now.timeIntervalSince(session.updatedAt))
            let state =
                session.isWorking(within: 45)
                ? (session.isRunningTool ? "runningTool" : "working") : "idle"
            print(
                "  \(session.id.prefix(13))  \(session.originator ?? "Codex")  "
                    + "\(project ?? "?")  [\(state)]  “\(session.title ?? "—")”")
            if !session.detail.isEmpty { print("      \(session.detail)") }
            print("      last written \(age)s ago")
        }
        return 0
    }

    static func tasks(_ sessionId: String) -> Int32 {
        let root = TaskReader.defaultRoot()
        guard !sessionId.isEmpty else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            print("tasks root  \(root.path)")
            for name in names.sorted() {
                let board = TaskReader.board(for: name)
                guard !board.isEmpty else { continue }
                print(
                    "  \(name)  \(board.completed) done, \(board.inProgress) running, "
                        + "\(board.open) open")
            }
            return 0
        }

        let board = TaskReader.board(for: sessionId)
        guard !board.isEmpty else {
            print("no tasks for \(sessionId) under \(root.path)")
            return 1
        }
        print("\(board.completed) done, \(board.inProgress) running, \(board.open) open")
        for task in board.tasks {
            let mark =
                switch task.status {
                case .inProgress: "●"
                case .pending: "☐"
                case .completed: "☑"
                }
            print("  \(mark) \(task.subject)")
        }
        return 0
    }

    /// Answers the oldest pending permission without using the UI.
    static func decide(_ decision: String, remember: Bool) -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = decision
        if remember { payload.prompt = "remember" }
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    /// Answers a pending `AskUserQuestion` from the command line — one comma-separated
    /// list of labels per question, in the order they were asked. This is how the answer
    /// path is exercised without a click.
    static func answer(_ labels: String) -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = "answer"
        payload.prompt = labels
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    /// The scrubbed report, straight to stdout so it can be piped or pasted.
    static func report() -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = "diagnose"
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    /// Checks for an update, and installs it with `--install`.
    static func update(install: Bool) -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = "update"
        if install { payload.prompt = "install" }
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    /// Opens the settings window of the instance that is already running.
    /// `Perch --reveal` opens the panel of the running instance.
    static func reveal() -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = "reveal"
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    static func settings() -> Int32 {
        var payload = ClaudeHookPayload()
        payload.message = "settings"
        return send(event: Wire.decideEvent, payload: payload) { _, status in
            print(status ?? "(no response)")
        }
    }

    /// Takes Perch back out of the login items. Run by `uninstall.sh` while the bundle is
    /// still on disk, because after it is deleted there is nothing left to call
    /// `unregister()` on and macOS keeps the entry until it next notices the app is gone.
    ///
    /// Unlike everything else here it talks to no running instance: the uninstaller quits
    /// Perch before it gets this far.
    static func forgetLoginItem() -> Int32 {
        LoginItem.apply(false)
        return 0
    }

    private static func send(
        event: String,
        payload: ClaudeHookPayload = ClaudeHookPayload(),
        report: (RuntimeInfo, String?) -> Void
    ) -> Int32 {
        guard let runtime = RuntimeInfo.load() else {
            print("Perch is not running (no ~/.perch/runtime.json)")
            return 1
        }

        var payload = payload
        payload.hookEventName = event
        let request = PerchRequest(
            token: runtime.token, event: event, wantsDecision: false, payload: payload)

        do {
            // Ten seconds, not three: right after launch the app is reloading its usage
            // aggregates on the main actor, and a CLI that gives up then reports "not
            // answering" about an app that is simply busy. Nothing here is on the hook
            // path, so waiting costs nobody a session.
            let data = try LineClient(port: runtime.port, timeout: 10)
                .roundTrip(JSONEncoder().encode(request))
            let response = try JSONDecoder().decode(PerchResponse.self, from: data)
            guard response.token == runtime.token else {
                print("response was not signed by Perch")
                return 1
            }
            report(runtime, response.status)
            return 0
        } catch {
            print("Perch is not answering on port \(runtime.port): \(error)")
            return 1
        }
    }

    private static func label(_ state: NotchState) -> String {
        switch state {
        case .idle: return "idle    "
        case .flash: return "flash   "
        case .peek: return "peek    "
        case .expanded: return "expanded"
        case .alert: return "alert   "
        }
    }

    private static func format(_ rect: CGRect) -> String {
        "x=\(round(rect.minX)) y=\(round(rect.minY)) w=\(round(rect.width)) h=\(round(rect.height))"
    }

    private static func format(_ size: CGSize) -> String {
        "w=\(round(size.width)) h=\(round(size.height))"
    }
}
