import Foundation
import Network
import PerchKit

/// Loopback line server that `perch-hook` talks to.
///
/// Binds an ephemeral port on 127.0.0.1 and publishes it, with a bearer token, to
/// `~/.perch/runtime.json`. One request per connection: the hook sends a line, we answer
/// a line, the connection closes. Permission requests simply take longer to answer
/// because a human is in the loop.
///
/// `@unchecked Sendable`: every stored property is either immutable or guarded by
/// `lock`. Network.framework hands us callbacks on `queue` while `start()`/`stop()` are
/// called from the main actor, so the listener reference is the one thing that needs it.
final class EventServer: @unchecked Sendable {
    typealias Handler = @Sendable (PerchRequest) async -> PerchResponse

    private let queue = DispatchQueue(label: "tech.kweli.perch.server")
    private let token = RuntimeInfo.newToken()
    private let handler: Handler
    private let lock = NSLock()
    private var _listener: NWListener?

    private var listener: NWListener? {
        get { lock.withLock { _listener } }
        set { lock.withLock { _listener = newValue } }
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Never expose this beyond the machine: the token alone should not be the only
        // thing standing between another host and approving tool calls.
        parameters.requiredInterfaceType = .loopback

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self, let port = listener.port else { return }
            self.publishRuntime(port: port.rawValue)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        RuntimeInfo.remove()
    }

    private func publishRuntime(port: UInt16) {
        let info = RuntimeInfo(port: port, token: token, pid: ProcessInfo.processInfo.processIdentifier)
        do {
            try info.write()
        } catch {
            NSLog("perch: could not write runtime.json: \(error)")
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { return connection.cancel() }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let index = accumulated.firstIndex(of: Wire.delimiter) else {
                // A hook payload can exceed one TCP segment; keep reading until the newline.
                if isComplete { connection.cancel() } else { self.receive(connection, buffer: accumulated) }
                return
            }

            let line = accumulated[accumulated.startIndex..<index]
            self.handle(line: Data(line), on: connection)
        }
    }

    private func handle(line: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(PerchRequest.self, from: line),
            request.token == token
        else {
            // Unauthenticated or malformed: say nothing, so the hook fails open.
            connection.cancel()
            return
        }

        let handler = self.handler
        Task {
            var response = await handler(request)
            response.token = self.token
            self.reply(response, on: connection)
        }
    }

    private func reply(_ response: PerchResponse, on connection: NWConnection) {
        guard var data = try? JSONEncoder().encode(response) else {
            connection.cancel()
            return
        }
        data.append(Wire.delimiter)
        connection.send(
            content: data,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
