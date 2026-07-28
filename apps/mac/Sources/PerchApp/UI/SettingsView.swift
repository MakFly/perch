import AppKit
import PerchKit
import SwiftUI

/// Everything Perch can be told, in one window.
///
/// Until now the quiet scenes, the admission filters and the sounds lived in JSON files
/// under `~/.perch`, which is fine for a tool you wrote and useless for one you install.
struct SettingsView: View {
    let model: AppModel

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case sound = "Sound"
        case filters = "Filters"
        case integrations = "Integrations"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .sound: return "speaker.wave.2"
            case .filters: return "line.3.horizontal.decrease.circle"
            case .integrations: return "puzzlepiece.extension"
            case .about: return "info.circle"
            }
        }
    }

    @State private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(t(item.rawValue), systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                Group {
                    switch pane {
                    case .general: GeneralPane(model: model)
                    case .sound: SoundPane(model: model)
                    case .filters: FiltersPane(model: model)
                    case .integrations: IntegrationsPane(model: model)
                    case .about: AboutPane(model: model)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: AppModel

    private var quiet: QuietSettings { model.quiet }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(
                t("Quiet scenes"),
                note: t(
                    "Perch stays silent while any of these is true — no panel, no sound, "
                        + "approvals included. Requests still queue and the session is still held; "
                        + "a dot marks them.")
            ) {
                Toggle(
                    t("A Focus mode is on"),
                    isOn: binding(\.duringFocus))
                Toggle(
                    t("The screen is locked or asleep"),
                    isOn: binding(\.whenScreenObscured))
                Toggle(
                    t("The screen is being recorded or shared"),
                    isOn: binding(\.whenScreenShared))
            }

            Section(
                t("Quiet hours"),
                note: t("Crosses midnight when the end is earlier than the start.")
            ) {
                Toggle(t("Silence during a time range"), isOn: quietHoursEnabled)
                if let hours = quiet.quietHours {
                    HStack(spacing: 12) {
                        TimeField(label: t("From"), minutes: quietHourBinding(\.start))
                        TimeField(label: t("Until"), minutes: quietHourBinding(\.end))
                        Text(rangeSummary(hours))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(
                t("Switcher"),
                note: t("Tap to open and pick with ↑↓, or hold and press again to cycle.")
            ) {
                Toggle(t("Enable the global shortcut"), isOn: switcherEnabled)
                HStack(spacing: 10) {
                    Text(t("Shortcut")).foregroundStyle(.secondary)
                    ShortcutRecorder(
                        keyCode: model.preferences.switcherKeyCode,
                        modifiers: model.preferences.switcherModifiers
                    ) { keyCode, modifiers in
                        var next = model.preferences
                        next.switcherKeyCode = keyCode
                        next.switcherModifiers = modifiers
                        model.updatePreferences(next)
                    }
                }
                .disabled(!model.preferences.switcherEnabled)
            }

            Section(
                t("Panel"),
                note: t(
                    "Clean keeps one line of chrome per session, so six agents still fit on "
                        + "screen. Detailed adds what you asked and the plan it is working "
                        + "through.")
            ) {
                Picker(t("Density"), selection: layout) {
                    ForEach(PanelLayout.allCases, id: \.self) { option in
                        Text(t(option.title)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(
                t("Notch"),
                note: "Zero trusts what macOS reports, which is right on every Mac this has "
                    + "been measured on. Adjust only if the panel does not sit over the cutout."
            ) {
                Slider(value: notchWidth, in: -60...60, step: 1) {
                    Text("Width \(Int(model.preferences.notchWidthAdjustment)) pt")
                        .monospacedDigit()
                }
                Slider(value: notchHeight, in: -12...24, step: 1) {
                    Text("Height \(Int(model.preferences.notchHeightAdjustment)) pt")
                        .monospacedDigit()
                }
                Button(t("Reset to what macOS reports")) {
                    var next = model.preferences
                    next.notchWidthAdjustment = 0
                    next.notchHeightAdjustment = 0
                    model.updatePreferences(next)
                }
            }

            Section(
                t("Updates"),
                note: t("Beta builds come from the same feed's neighbour, signed by the same key.")
            ) {
                Toggle(t("Take beta builds"), isOn: beta)
                HStack {
                    Button(t("Copy diagnostic report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticReport(), forType: .string)
                    }
                    Text(
                        t(
                            "Paths are shortened, project names are hashed, and no command "
                                + "or prompt is included.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section(
                t("Idle sessions"),
                note: t(
                    "Only bites CLIs that close without saying so. Claude Code always "
                        + "sends SessionEnd, so “never” loses nothing if it is all you run.")
            ) {
                Picker(t("Forget a silent session after"), selection: idleTimeout) {
                    Text(t("Never")).tag(TimeInterval(0))
                    Text(t("30 minutes")).tag(TimeInterval(30 * 60))
                    Text(t("1 hour")).tag(TimeInterval(3_600))
                    Text(t("2 hours")).tag(TimeInterval(2 * 3_600))
                    Text(t("8 hours")).tag(TimeInterval(8 * 3_600))
                    Text(t("24 hours")).tag(TimeInterval(24 * 3_600))
                }
                .fixedSize()
            }

            Section(t("Notifications"), note: nil) {
                Toggle(
                    t("Stay quiet when the asking terminal is already in front"),
                    isOn: binding(\.smartSuppression))
                Toggle(t("Play sounds"), isOn: binding(\.soundEnabled))
                Toggle(
                    t("Notify me when a turn ends somewhere I cannot see"),
                    isOn: binding(\.notifiesOnComplete))
                Text(
                    t(
                        "A macOS notification, silent — Perch already owns the sound. It "
                            + "stays quiet in a quiet scene, during quiet hours, and while "
                            + "you are looking at the terminal that raised it. Clicking it "
                            + "jumps there."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    t("Open the panel when a task finishes"),
                    isOn: binding(\.autoExpandOnComplete))
                Text("Off by default — a chime per finished turn is how people end up muting an app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ path: WritableKeyPath<QuietSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.quiet[keyPath: path] },
            set: { value in
                var settings = model.quiet
                settings[keyPath: path] = value
                model.updateQuiet(settings)
            })
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding(
            get: { model.quiet.quietHours != nil },
            set: { value in
                var settings = model.quiet
                settings.quietHours = value ? QuietHours(start: 22 * 60, end: 7 * 60) : nil
                model.updateQuiet(settings)
            })
    }

    private func quietHourBinding(_ path: WritableKeyPath<QuietHours, Int>) -> Binding<Int> {
        Binding(
            get: { model.quiet.quietHours?[keyPath: path] ?? 0 },
            set: { value in
                var settings = model.quiet
                settings.quietHours?[keyPath: path] = value
                model.updateQuiet(settings)
            })
    }

    private func rangeSummary(_ hours: QuietHours) -> String {
        hours.start > hours.end ? t("crosses midnight") : ""
    }

    private var switcherEnabled: Binding<Bool> {
        Binding(
            get: { model.preferences.switcherEnabled },
            set: { value in
                var next = model.preferences
                next.switcherEnabled = value
                model.updatePreferences(next)
            })
    }

    private var notchWidth: Binding<Double> {
        Binding(
            get: { model.preferences.notchWidthAdjustment },
            set: { value in
                var next = model.preferences
                next.notchWidthAdjustment = value
                model.updatePreferences(next)
            })
    }

    private var notchHeight: Binding<Double> {
        Binding(
            get: { model.preferences.notchHeightAdjustment },
            set: { value in
                var next = model.preferences
                next.notchHeightAdjustment = value
                model.updatePreferences(next)
            })
    }

    private var layout: Binding<PanelLayout> {
        Binding(
            get: { model.preferences.layout },
            set: { value in
                var next = model.preferences
                next.layout = value
                model.updatePreferences(next)
            })
    }

    private var beta: Binding<Bool> {
        Binding(
            get: { model.preferences.betaUpdates },
            set: { value in
                var next = model.preferences
                next.betaUpdates = value
                model.updatePreferences(next)
            })
    }

    private var idleTimeout: Binding<TimeInterval> {
        Binding(
            get: { model.preferences.idleTimeout },
            set: { value in
                var next = model.preferences
                next.idleTimeout = value
                model.updatePreferences(next)
            })
    }
}

/// Records a shortcut by listening for one key press while focused.
///
/// The recorder deliberately refuses a bare letter: a global shortcut with no modifier
/// would swallow that key in every app on the machine.
private struct ShortcutRecorder: View {
    let keyCode: UInt32
    let modifiers: UInt32
    let onRecord: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(
                    isRecording
                        ? t("Press a shortcut…")
                        : ShortcutFormatter.describe(keyCode: keyCode, modifiers: modifiers)
                )
                .frame(minWidth: 120)
            }
            if rejected {
                Text(t("Needs ⌃, ⌥ or ⌘"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbon = ShortcutFormatter.carbonModifiers(
                fromCocoa: UInt(event.modifierFlags.rawValue))
            let code = UInt32(event.keyCode)
            if ShortcutFormatter.isUsable(keyCode: code, modifiers: carbon) {
                onRecord(code, carbon)
                stop()
            } else {
                rejected = true
            }
            // Swallow it either way: the point of recording is that the key does not act.
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct TimeField: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Stepper(value: $minutes, in: 0...(24 * 60 - 15), step: 15) {
                Text(String(format: "%02d:%02d", minutes / 60, minutes % 60))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }
}

// MARK: - Sound

private struct SoundPane: View {
    let model: AppModel

    private var sounds: SoundSettings { model.sounds }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(
                t("Sound"),
                note: t(
                    "Perch ships no audio of its own. A source is a macOS system sound, a "
                        + "file you picked, or nothing at all.")
            ) {
                Toggle(t("Play sounds"), isOn: enabled)
                HStack {
                    Text(t("Volume")).foregroundStyle(.secondary)
                    Slider(value: volume, in: 0...1)
                    Text(String(format: "%.0f%%", sounds.volume * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .disabled(!sounds.enabled)
            }

            Section(
                t("Packs"),
                note: t(
                    "A pack is a folder of audio files with a manifest. Applying one points "
                        + "the events it covers at its files and leaves the rest alone.")
            ) {
                HStack {
                    Button(t("Import a pack…")) { importPack() }
                    if packs.isEmpty {
                        Text(t("No packs installed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                ForEach(packs, id: \.name) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pack.name)
                            Text(
                                pack.author.map { "\($0) · \(pack.sounds.count) sounds" }
                                    ?? "\(pack.sounds.count) sounds"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(t("Apply")) {
                            var next = model.sounds
                            next.apply(pack)
                            model.updateSounds(next)
                        }
                    }
                }
            }

            Section(
                t("Per event"),
                note: t(
                    "The noisy ones start silent: a chime for every finished turn is how an "
                        + "app gets muted for good.")
            ) {
                ForEach(InterruptionKind.allCases, id: \.rawValue) { kind in
                    HStack(spacing: 8) {
                        Text(t(kind.title))
                            .frame(width: 170, alignment: .leading)

                        Picker("", selection: source(for: kind)) {
                            Text(t("Off")).tag(SoundSource.off)
                            ForEach(SoundSettings.systemNames, id: \.self) { name in
                                Text(name).tag(SoundSource.system(name))
                            }
                            // A picked file is not in the list, so it needs its own row or
                            // the selection would silently fall back to Off.
                            if case .file(let path) = sounds.source(for: kind) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .tag(SoundSource.file(path))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)

                        Button(t("Choose…")) { chooseFile(for: kind) }
                        Button(t("Preview")) {
                            SoundPlayer.preview(sounds.source(for: kind), volume: sounds.volume)
                        }
                        .disabled(sounds.source(for: kind) == .off)

                        Spacer()
                    }
                    .disabled(!sounds.enabled)
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.sounds.enabled },
            set: { value in
                var next = model.sounds
                next.enabled = value
                model.updateSounds(next)
            })
    }

    private var volume: Binding<Double> {
        Binding(
            get: { model.sounds.volume },
            set: { value in
                var next = model.sounds
                next.volume = value
                model.updateSounds(next)
            })
    }

    private func source(for kind: InterruptionKind) -> Binding<SoundSource> {
        Binding(
            get: { model.sounds.source(for: kind) },
            set: { value in
                var next = model.sounds
                next.setSource(value, for: kind)
                model.updateSounds(next)
                // Play it as it is picked: choosing a sound you cannot hear is guesswork.
                SoundPlayer.preview(value, volume: next.volume)
            })
    }

    @State private var packs: [SoundPack] = SoundPack.installed()

    /// Copies the folder in rather than referencing it where it sits: a pack imported from
    /// Downloads should survive the Downloads folder being cleared.
    private func importPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = t("Import a pack…")
        guard panel.runModal() == .OK, let source = panel.url else { return }

        guard SoundPack.load(from: source) != nil else {
            let alert = NSAlert()
            alert.messageText = t("That folder is not a sound pack")
            alert.informativeText = t(
                "A pack needs a pack.json naming which file plays for which event, and the "
                    + "files it names have to be there.")
            alert.runModal()
            return
        }

        let destination = SoundPack.installedDirectory
            .appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.createDirectory(
            at: SoundPack.installedDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        packs = SoundPack.installed()
    }

    private func chooseFile(for kind: InterruptionKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = t("Choose…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var next = model.sounds
        next.setSource(.file(url.path), for: kind)
        model.updateSounds(next)
        SoundPlayer.preview(.file(url.path), volume: next.volume)
    }
}

// MARK: - Filters

private struct FiltersPane: View {
    let model: AppModel

    @State private var draft = ""
    @State private var field: AdmissionRule.Field = .directory
    @State private var match: AdmissionRule.Match = .contains
    @State private var launcher = ""

    private var policy: AdmissionPolicy { model.activity.admission }

    /// How many sessions on screen right now the draft would hide. Shown live so nobody
    /// commits to a rule that silences everything.
    private var previewCount: Int {
        guard !draft.isEmpty else { return 0 }
        let rule = AdmissionRule(field: field, match: match, pattern: draft)
        return policy.matchCount(
            of: rule,
            in: model.activity.activeSessions.map { ($0.cwd, $0.prompt) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(
                t("Presets"),
                note:
                    "Known background sessions. Off by default — hiding a session you wanted "
                    + "is the expensive mistake."
            ) {
                ForEach(policy.presetRules) { rule in
                    Toggle(isOn: enabled(rule.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.note ?? rule.pattern)
                            Text("\(rule.field.rawValue) \(rule.match.rawValue) “\(rule.pattern)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(t("Your filters"), note: t("Right-clicking a session card adds one too.")) {
                HStack(spacing: 8) {
                    Picker("", selection: $field) {
                        Text(t("Directory")).tag(AdmissionRule.Field.directory)
                        Text(t("Prompt")).tag(AdmissionRule.Field.prompt)
                    }
                    .labelsHidden()
                    .fixedSize()

                    Picker("", selection: $match) {
                        Text(t("contains")).tag(AdmissionRule.Match.contains)
                        Text(t("starts with")).tag(AdmissionRule.Match.prefix)
                    }
                    .labelsHidden()
                    .fixedSize()

                    TextField(t("pattern"), text: $draft)
                        .textFieldStyle(.roundedBorder)

                    if !draft.isEmpty {
                        Text("\(previewCount) match\(previewCount == 1 ? "" : "es")")
                            .font(.caption)
                            .foregroundStyle(previewCount > 0 ? .orange : .secondary)
                    }

                    Button(t("Add")) {
                        var updated = policy
                        updated.add(
                            AdmissionRule(field: field, match: match, pattern: draft))
                        model.activity.updateAdmission(updated)
                        draft = ""
                    }
                    .disabled(draft.isEmpty)
                }

                if policy.custom.isEmpty {
                    Text(t("No filters of your own yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(policy.custom) { rule in
                        HStack {
                            Toggle(isOn: enabled(rule.id)) {
                                Text("\(rule.field.rawValue) \(rule.match.rawValue) “\(rule.pattern)”")
                                    .font(.callout)
                            }
                            Spacer()
                            Button(t("Remove")) {
                                var updated = policy
                                updated.remove(id: rule.id)
                                model.activity.updateAdmission(updated)
                            }
                        }
                    }
                }
            }

            Section(
                t("Blocked launcher apps"),
                note:
                    "For helpers that drive an agent without a terminal, where a directory "
                    + "or prompt rule has nothing to bite on."
            ) {
                HStack {
                    TextField("bundle identifier, e.g. com.example.helper", text: $launcher)
                        .textFieldStyle(.roundedBorder)
                    Button(t("Choose App…")) { chooseApp() }
                    Button(t("Block")) {
                        var next = model.preferences
                        next.blockedLaunchers.append(launcher)
                        model.updatePreferences(next)
                        launcher = ""
                    }
                    .disabled(launcher.isEmpty)
                }

                if model.preferences.blockedLaunchers.isEmpty {
                    Text(t("Nothing blocked.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.preferences.blockedLaunchers, id: \.self) { bundleId in
                        HStack {
                            Text(bundleId).font(.callout)
                            Spacer()
                            Button(t("Unblock")) {
                                var next = model.preferences
                                next.blockedLaunchers.removeAll { $0 == bundleId }
                                model.updatePreferences(next)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Typing a bundle identifier from memory is a good way to block nothing at all.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = t("Block")
        guard panel.runModal() == .OK, let url = panel.url,
            let bundleId = Bundle(url: url)?.bundleIdentifier
        else { return }
        launcher = bundleId
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { policy.rules.first { $0.id == id }?.enabled ?? false },
            set: { value in
                var updated = policy
                updated.setEnabled(value, id: id)
                model.activity.updateAdmission(updated)
            })
    }
}

// MARK: - Integrations

private struct IntegrationsPane: View {
    let model: AppModel

    /// Projects that install Perch on top of the global hooks. Read here rather than
    /// remembered, so the warning goes away the moment the extra install does.
    private var duplicatedSites: Int { model.activity.health.duplicatedSites }

    /// Off is zero rather than a separate flag, so there is one number to read and no way
    /// to be "enabled at 0%". Turning it back on restores the default rather than the last
    /// value: a threshold you disabled is not one you were happy with.
    private var warningEnabled: Binding<Bool> {
        Binding(
            get: { model.preferences.quotaWarningThreshold > 0 },
            set: { value in
                var next = model.preferences
                next.quotaWarningThreshold = value ? 90 : 0
                model.updatePreferences(next)
            })
    }

    private var warningThreshold: Binding<Double> {
        Binding(
            get: { model.preferences.quotaWarningThreshold },
            set: { value in
                var next = model.preferences
                next.quotaWarningThreshold = value
                model.updatePreferences(next)
            })
    }

    private var showsRemaining: Binding<Bool> {
        Binding(
            get: { model.preferences.showsRemainingQuota },
            set: { value in
                var next = model.preferences
                next.showsRemainingQuota = value
                model.updatePreferences(next)
            })
    }

    private var directQuota: Binding<Bool> {
        Binding(
            get: { model.preferences.directQuota },
            set: { value in
                var next = model.preferences
                next.directQuota = value
                model.updatePreferences(next)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(
                t("Hooks"),
                note:
                    "Hooks are read when a session starts, so a session already open will "
                    + "ignore a fresh install until it is restarted."
            ) {
                ForEach(HookSite.discover(), id: \.path) { site in
                    HStack {
                        Image(systemName: site.isInstalled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(site.isInstalled ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(site.title)
                            Text(site.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(site.isInstalled ? "\(site.eventCount) events" : t("not installed"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Installing both scopes is not extra safety: Claude Code runs both, so
                // the session is hooked twice. Perch drops the copies, which is precisely
                // why this has to be said somewhere — otherwise nothing looks wrong.
                if duplicatedSites > 0 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text(
                            t(
                                "%lld projects also install Perch on top of the global "
                                    + "hooks. Every event fires twice; Perch shows it once. "
                                    + "Remove the project copy with "
                                    + "./scripts/install-hooks.sh --uninstall <project>.",
                                duplicatedSites)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
                Text("Install with ./scripts/install-hooks.sh <project> or --codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let trust = CodexTrust.status() {
                Section(
                    t("Codex trust"),
                    note:
                        "Codex asks before letting anything run on its events. Perch reads "
                        + "that state; it will not write to it — forging an entry in a "
                        + "security store to save you one command is the wrong trade."
                ) {
                    HStack {
                        Image(
                            systemName: trust.isFullyTrusted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(trust.isFullyTrusted ? Color.green : Color.orange)
                        Text(
                            trust.isFullyTrusted
                                ? "All \(trust.installedPositions) hooks are trusted"
                                : "\(trust.trustedPositions) of \(trust.installedPositions) hooks trusted"
                        )
                        Spacer()
                    }
                    if trust.needsTrust {
                        Text(t("Run /hooks in Codex and approve the Perch entries."))
                            .font(.callout)
                    }
                }
            }

            Section(
                t("Plan quota"),
                note:
                    "The statusline bridge replays the same bytes to your original command, "
                    + "so what you see there is unchanged."
            ) {
                Toggle(t("Tell me when a window fills up"), isOn: warningEnabled)
                if model.preferences.quotaWarningThreshold > 0 {
                    Slider(value: warningThreshold, in: 50...100, step: 5) {
                        Text(
                            String(
                                format: "%.0f%%", model.preferences.quotaWarningThreshold)
                        )
                        .monospacedDigit()
                    }
                    Text(
                        t(
                            "The notch shows itself once, when a window crosses that line — "
                                + "and stays quiet during a screen share like everything else."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(t("Show what is left rather than what is used"), isOn: showsRemaining)
            }

            Section(t("Connection"), note: nil) {
                HStack {
                    Image(
                        systemName: model.usage.bridgeLimits == nil
                            ? "circle" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(
                        model.usage.bridgeLimits == nil ? Color.secondary : Color.green)
                    Text(
                        model.usage.bridgeLimits == nil
                            ? "Statusline bridge not connected — run ./scripts/usage-bridge.sh"
                            : t("Statusline bridge connected"))
                    Spacer()
                }

                // The second source, and the only place Perch reads a secret. What that
                // means is said here rather than in a changelog nobody reads.
                Toggle(t("Also read the quota from Anthropic directly"), isOn: directQuota)
                Text(
                    t(
                        "Uses the Claude Code credential already in your Keychain — macOS "
                            + "asks once. The token is read for each request and dropped: "
                            + "never stored, never logged, never sent anywhere but "
                            + "api.anthropic.com. Useful when your statusline is off, "
                            + "because that is the only thing that publishes the quota "
                            + "locally."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.preferences.directQuota, let summary = model.usage.directSummary {
                    HStack {
                        Image(
                            systemName: model.usage.directLimits == nil
                                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            model.usage.directLimits == nil ? Color.orange : Color.green)
                        Text(summary).font(.callout)
                        Spacer()
                    }
                }
                if let reading = model.usage.limits {
                    ForEach(reading.limits.windows) { window in
                        HStack {
                            Text(window.title).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%% used", window.window.utilization ?? 0))
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

/// Where hooks are installed, read back from disk so the pane reports what is true rather
/// than what Perch believes it did.
struct HookSite {
    var title: String
    var path: String
    var isInstalled: Bool
    var eventCount: Int

    static func discover() -> [HookSite] {
        let home = NSHomeDirectory()
        var candidates: [(String, String)] = [
            (t("Claude Code (global)"), "\(home)/.claude/settings.json"),
            (t("Codex"), "\(home)/.codex/hooks.json"),
        ]

        // Project sites Perch recorded when it installed them.
        let registry = URL(fileURLWithPath: home).appendingPathComponent(".perch/hook-sites.json")
        if let data = try? Data(contentsOf: registry),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        {
            for path in paths where !candidates.contains(where: { $0.1 == path }) {
                let project = URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .lastPathComponent
                candidates.append((project, path))
            }
        }

        return candidates.map { title, path in
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let events = text.components(separatedBy: "perch-hook").count - 1
            return HookSite(
                title: title, path: path, isInstalled: events > 0, eventCount: events)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Perch").font(.title2).bold()

            if let updates = model?.updates, updates.isConfigured {
                if let item = updates.available {
                    HStack {
                        Text(t("Version %@ is available", item.version))
                        Button(t("Update and relaunch")) {
                            Task { await updates.install(item) }
                        }
                        .disabled(updates.isInstalling)
                        if updates.isInstalling { ProgressView().controlSize(.small) }
                    }
                    if let error = updates.lastError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    }
                } else {
                    HStack {
                        Text(t("Up to date · %@", updates.currentVersion))
                            .foregroundStyle(.secondary)
                        Button(t("Check again")) { Task { await updates.check() } }
                    }
                }
                Divider()
            }

            Text("Approve Claude Code from your MacBook's notch — and see where your tokens go.")
                .foregroundStyle(.secondary)
            Divider()
            Text("⌃⌥P opens the session switcher from anywhere.")
            Text("Clicking a session card jumps to its terminal.")
            Text("Right-clicking one silences its directory or its prompt.")
            Divider()
            Text("Settings live in ~/.perch — quiet.json and admission.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared

private struct Section<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
