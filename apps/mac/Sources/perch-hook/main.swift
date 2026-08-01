import Foundation
import PerchKit

// Invoked by Claude Code hooks:
//
//     perch-hook <EventName> [--timeout <seconds>]
//
// Reads the hook payload on stdin, forwards it to Perch.app, and — for permission
// events — writes Claude Code's decision JSON back on stdout.
//
// Every failure path exits 0 with no stdout. If Perch is not running, is wedged, or
// answers nonsense, Claude Code must behave exactly as if this hook did not exist.

/// Events where we block and wait for the user to decide in the notch.
let decisionEvents: Set<String> = ["PermissionRequest"]

func parseArguments() -> (event: String, timeout: TimeInterval?, source: String?) {
    var event = "Unknown"
    var timeout: TimeInterval?
    var source: String?
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()
        if argument == "--timeout" {
            if let value = arguments.first.flatMap(Double.init) {
                timeout = value
                arguments.removeFirst()
            }
        } else if argument == "--source" {
            source = arguments.first
            if source != nil { arguments.removeFirst() }
        } else if !argument.hasPrefix("--") {
            event = argument
        }
    }
    return (event, timeout, source)
}

func readStdin() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

/// The hook is silent by design, which makes a broken install hard to diagnose.
/// `PERCH_DEBUG=1` narrates to stderr; Claude Code shows stderr on non-zero exits and
/// ignores it otherwise, so this stays safe to leave on.
let isDebug = ProcessInfo.processInfo.environment["PERCH_DEBUG"] == "1"

func debug(_ message: @autoclosure () -> String) {
    guard isDebug else { return }
    FileHandle.standardError.write(Data("perch-hook: \(message())\n".utf8))
}

let (eventArgument, timeoutOverride, sourceArgument) = parseArguments()
let input = readStdin()

// Decode leniently: an unparseable payload is still worth forwarding as an event.
let decoder = JSONDecoder()
let payload = (try? decoder.decode(ClaudeHookPayload.self, from: input)) ?? ClaudeHookPayload()

// The payload's own event name wins — argv is only a fallback.
let event = payload.hookEventName ?? eventArgument

/// Events for which the untyped copy of the payload is worth building.
///
/// `raw` exists for one reader: `subagentLabel`, which hunts for whichever key the CLI
/// used to name a subagent because the spelling has moved between releases. That is a
/// question only the subagent events ask. Building it for every event meant re-decoding
/// the whole payload a second time — including a `PostToolUse` carrying a file's entire
/// contents — to answer a question nobody asked, in a process holding a blocked session.
let rawEvents: Set<String> = ["SubagentStart", "SubagentStop"]
let raw = rawEvents.contains(event) ? try? decoder.decode(JSONValue.self, from: input) : nil
let wantsDecision = decisionEvents.contains(event)
// A day for decisions, matching the hook entry the installer writes: the app owns the
// deadline. Telemetry events get two seconds and are never worth stalling a session for.
let timeout = timeoutOverride ?? (wantsDecision ? 86_400 : 2)

guard let runtime = RuntimeInfo.load() else {
    debug("no runtime.json — is Perch running? (failing open)")
    exit(0)
}

let request = PerchRequest(
    token: runtime.token,
    event: event,
    wantsDecision: wantsDecision,
    payload: payload,
    raw: raw,
    // The hook runs inside the terminal that runs Claude Code, so this is the only place
    // the host is knowable. stdin is the payload pipe, so the tty comes off stderr.
    client: ClientInfo.fromEnvironment(tty: ttyname(2).map { String(cString: $0) }),
    agent: Agent(source: sourceArgument)
)

guard let encoded = try? JSONEncoder().encode(request) else { exit(0) }

debug("event=\(event) tool=\(payload.toolName ?? "-") port=\(runtime.port) timeout=\(timeout)s")

let client = LineClient(port: runtime.port, timeout: timeout)
let responseData: Data
do {
    responseData = try client.roundTrip(encoded)
} catch {
    debug("transport failed: \(error) (failing open)")
    exit(0)
}

debug("reply: \(String(data: responseData, encoding: .utf8) ?? "<binary>")")

guard let response = try? decoder.decode(PerchResponse.self, from: responseData) else { exit(0) }

// Only Perch knows the token (runtime.json is 0600), so this rejects any impostor that
// took over the port — otherwise it could approve tool calls by answering `allow`.
guard response.token == runtime.token else {
    debug("response token mismatch — ignoring (failing open)")
    exit(0)
}

guard wantsDecision else { exit(0) }

// Built by the same code the remote shell hook is handed, rather than assembled a second
// time here. This file used to spell the schema out itself, and it silently fell a field
// behind: an approved plan's mode never reached Claude Code. `nil` covers both "no
// decision" and `ask` — deferring to Claude Code's own prompt means printing nothing.
guard let data = response.renderedOutput(event: event) else { exit(0) }
FileHandle.standardOutput.write(data)
exit(0)
