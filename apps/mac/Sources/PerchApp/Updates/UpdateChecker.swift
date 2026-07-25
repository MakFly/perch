import AppKit
import Foundation
import Observation
import PerchKit

/// Checks the update feed, verifies what it finds, and offers the download.
///
/// It does not install anything by itself. Silent self-replacement is Sparkle's job and
/// Sparkle's risk surface; this covers the part that matters — telling you an update
/// exists, and *proving* it came from whoever holds the signing key before saying so.
///
/// With no `SUPublicEDKey` in the bundle, checking is off entirely. An app that cannot
/// verify an update has no business fetching one.
@MainActor
@Observable
final class UpdateChecker {
    private(set) var available: AppcastItem?
    private(set) var lastCheckedAt: Date?
    private(set) var lastError: String?

    /// Set from Settings. The beta feed is the release feed's neighbour — `appcast.xml`
    /// becomes `appcast-beta.xml` — so it is one more file to publish rather than another
    /// service to run, and it is signed by the same key.
    var wantsBeta = false

    private var feedURL: URL? {
        guard
            let base = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
                .flatMap(URL.init(string:))
        else { return nil }
        guard wantsBeta else { return base }

        let name = base.deletingPathExtension().lastPathComponent
        return base
            .deletingLastPathComponent()
            .appendingPathComponent("\(name)-beta")
            .appendingPathExtension(base.pathExtension)
    }

    private var publicKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    var isConfigured: Bool { feedURL != nil && publicKey != nil }

    func check() async {
        guard let feedURL, publicKey != nil else { return }
        lastError = nil

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 15
            // The feed is small and changes rarely; a stale cached copy would hide an
            // update for as long as the cache lives.
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let xml = String(data: data, encoding: .utf8) else {
                lastError = "The update feed was not readable"
                return
            }

            lastCheckedAt = .now
            available = Appcast.update(in: Appcast.parse(xml), current: currentVersion)
        } catch {
            // A missed check is not worth telling anyone about; it will run again.
            lastError = nil
        }
    }

    private(set) var isInstalling = false

    /// Downloads the update, verifies it, and replaces this app with it.
    ///
    /// Every step can refuse. The signature is checked before the bytes touch disk as an
    /// app; the mounted bundle's identifier is checked before anything is copied; the old
    /// app is kept until the new one is in place. An updater that half-succeeds leaves a
    /// user with no app at all, which is worse than never updating.
    func install(_ item: AppcastItem) async {
        guard let publicKey, !isInstalling else { return }
        isInstalling = true
        lastError = nil
        defer { isInstalling = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: item.url)

            guard Appcast.verify(data: data, signature: item.signature, publicKey: publicKey)
            else {
                // Not "could not verify" — this is a file that is not what it claims.
                lastError = "That download was not signed by Perch's key — discarded"
                return
            }

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("perch-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            let image = staging.appendingPathComponent(item.url.lastPathComponent)
            try data.write(to: image, options: .atomic)

            guard let newApp = try mount(image, at: staging) else {
                lastError = "The update did not contain a Perch app"
                return
            }

            try Updater.scheduleSwap(from: newApp, over: Bundle.main.bundleURL, staging: staging)
            // The swap script waits for this process to exit before touching anything.
            NSApp.terminate(nil)
        } catch {
            lastError = "Update failed: \(error.localizedDescription)"
        }
    }

    /// Mounts the disk image and returns the app inside, if it really is one of ours.
    private func mount(_ image: URL, at staging: URL) throws -> URL? {
        let mountPoint = staging.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(
            at: mountPoint, withIntermediateDirectories: true)

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = [
            "attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path,
        ]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else { return nil }

        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            return nil
        }

        // The signature proves who built it; this proves it is the same product. Swapping
        // a correctly-signed *different* app over Perch would still be a surprise.
        let identifier = Bundle(url: app)?.bundleIdentifier
        guard identifier == Bundle.main.bundleIdentifier else { return nil }

        return app
    }
}

/// Writes the script that does the swap after Perch exits.
///
/// A process cannot reliably replace its own bundle while running, so the last thing Perch
/// does is hand the job to something that outlives it.
enum Updater {
    static func scheduleSwap(from newApp: URL, over currentApp: URL, staging: URL) throws {
        let script = staging.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier

        // `ditto` rather than `cp`: it preserves the bundle's extended attributes and its
        // code signature, and `cp` quietly does not.
        let body = """
            #!/bin/sh
            # Waits for Perch to exit, swaps the bundle, relaunches, cleans up.
            for _ in $(seq 1 100); do
              kill -0 \(pid) 2>/dev/null || break
              sleep 0.1
            done

            BACKUP="\(currentApp.path).old"
            rm -rf "$BACKUP"
            mv "\(currentApp.path)" "$BACKUP" || exit 1

            if ! ditto "\(newApp.path)" "\(currentApp.path)"; then
              # Put the working app back rather than leaving nothing behind.
              rm -rf "\(currentApp.path)"
              mv "$BACKUP" "\(currentApp.path)"
              exit 1
            fi

            rm -rf "$BACKUP"
            hdiutil detach "\(staging.appendingPathComponent("mnt").path)" -quiet 2>/dev/null
            open "\(currentApp.path)"
            rm -rf "\(staging.path)"
            """

        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
    }
}
