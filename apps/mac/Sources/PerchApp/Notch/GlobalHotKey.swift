import AppKit
import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut, registered through Carbon.
///
/// `RegisterEventHotKey` is the one way to get a global shortcut without Accessibility
/// permission — a `CGEventTap` or a global `NSEvent` monitor would both prompt for it, and
/// Perch's whole posture is that it never asks. The API is ancient and C-shaped, which is
/// the price.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥P by default: unclaimed by macOS and by the editors people run alongside.
    static let defaultKeyCode = UInt32(kVK_ANSI_P)
    static let defaultModifiers = UInt32(controlKey | optionKey)

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: ((Bool) -> Void)?
    private var flagsMonitor: Any?
    private var onRelease: (() -> Void)?

    /// Carbon dispatches by id, so every hot key needs a unique one.
    private static let signature = OSType(0x50524348)  // 'PRCH'
    private static var nextId: UInt32 = 1

    /// `onPress` receives true when Shift was held, which is the reverse direction.
    func register(
        keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
        modifiers: UInt32 = GlobalHotKey.defaultModifiers,
        onPress: @escaping (Bool) -> Void,
        onRelease: @escaping () -> Void
    ) {
        unregister()
        self.onPress = onPress
        self.onRelease = onRelease

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, context in
            guard let context, let event else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Shift is not part of the registration, so it is read at press time — that is
            // what lets one shortcut cycle both ways.
            let reverse = NSEvent.modifierFlags.contains(.shift)
            var identifier = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            Task { @MainActor in owner.onPress?(reverse) }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler)

        let hotKeyId = EventHotKeyID(signature: Self.signature, id: Self.nextId)
        Self.nextId += 1

        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            NSLog("perch: could not register the switcher shortcut (\(status))")
        }

        // Releasing the modifier is what ⌘Tab-style cycling ends on. A *global* key
        // monitor would need Accessibility, but the panel takes focus once the switcher
        // opens, so a local monitor sees the release without asking for anything.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let held = event.modifierFlags.intersection([.control, .option])
            if held.isEmpty {
                Task { @MainActor in self?.onRelease?() }
            }
            return event
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    // No `deinit` cleanup: the Carbon handles are main-actor state and Swift 6 will not
    // let a nonisolated deinit touch them. Perch owns exactly one of these for the life of
    // the process and unregisters it on quit, so there is nothing to leak.
}
