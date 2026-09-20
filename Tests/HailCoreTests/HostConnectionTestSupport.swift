import Foundation
import HailCore
import HailProtocol

enum SocketTestError: Error, Sendable { case closed, unavailable }

actor ScriptedSocket: WebSocketTransport {
    private var incoming: [Result<Data, any Error>] = []
    private var waiters: [UnsafeContinuation<Data, any Error>] = []
    private var outgoing: [Data] = []
    private(set) var closeCount = 0
    private let finishReceiveOnClose: Bool

    init(finishReceiveOnClose: Bool = true) {
        self.finishReceiveOnClose = finishReceiveOnClose
    }

    func send(_ data: Data) { outgoing.append(data) }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        // Xcode 26 can corrupt checked throwing-continuation teardown in this cancellation shape
        // (swiftlang/swift#84793). The actor owns exact-once resume, so the unsafe variant is bounded here.
        return try await withUnsafeThrowingContinuation { waiters.append($0) }
    }

    func close() {
        closeCount += 1
        guard finishReceiveOnClose else { return }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: SocketTestError.closed) }
    }

    func push(_ control: ControlPayload, version: Int = ProtocolVersion.current) throws {
        let frame = Frame(timestamp: 1, source: "haild", payload: .control(control))
        try push(FrameCoding.encode(Frame(
            version: version, id: frame.id, timestamp: frame.timestamp, source: frame.source, payload: frame.payload
        )))
    }

    func push(_ data: Data) throws {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            incoming.append(.success(data))
        }
    }

    func fail() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(throwing: SocketTestError.closed)
        } else {
            incoming.append(.failure(SocketTestError.closed))
        }
    }

    func sentFrames() throws -> [Frame] { try outgoing.map { try FrameCoding.decode($0) } }
}

actor ScriptedConnector: WebSocketConnecting {
    enum Step: Sendable {
        case socket(any WebSocketTransport)
        case failure
    }

    private var stepsByURL: [URL: [Step]] = [:]
    private(set) var opens: [(URL, String)] = []

    func enqueue(_ step: Step, for url: URL) {
        stepsByURL[url, default: []].append(step)
    }

    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        opens.append((url, subprotocol))
        guard var steps = stepsByURL[url], !steps.isEmpty else { throw SocketTestError.unavailable }
        let step = steps.removeFirst()
        stepsByURL[url] = steps
        switch step {
        case .socket(let socket): return socket
        case .failure: throw SocketTestError.unavailable
        }
    }

    func openCount(for url: URL) -> Int { opens.count { $0.0 == url } }
}

actor SnapshotRecorder {
    private(set) var values: [HostConnectionSnapshot] = []
    func append(_ value: HostConnectionSnapshot) { values.append(value) }
    func states() -> [HostConnectionState] { values.map(\.state) }
}

actor SleepRecorder {
    private(set) var durations: [Duration] = []
    func sleep(_ duration: Duration) { durations.append(duration) }
}

actor SleepGate {
    private var waiter: UnsafeContinuation<Void, any Error>?

    func sleep(_ duration: Duration) async throws {
        _ = duration
        // See ScriptedSocket.receive(): actor ownership provides exact-once resume.
        try await withUnsafeThrowingContinuation { waiter = $0 }
    }

    func isWaiting() -> Bool { waiter != nil }

    func fire() {
        waiter?.resume()
        waiter = nil
    }
}

final class TestInstantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    func now() -> ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []

    func schedule(_ duration: Duration, action: @escaping @Sendable () -> Void) {
        _ = duration
        lock.withLock { actions.append(action) }
    }

    func fire() {
        let pending = lock.withLock {
            actions.isEmpty ? nil : actions.removeFirst()
        }
        pending?()
    }
}

func endpoint(_ id: String = "mac-1", _ url: String = "ws://127.0.0.1:8765") throws -> HostEndpoint {
    try HostEndpoint(id: id, name: id, url: requireURL(url))
}

private func requireURL(_ value: String) -> URL {
    guard let url = URL(string: value) else { preconditionFailure("invalid test URL") }
    return url
}

func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw SocketTestError.unavailable
}

func hostHello(version: Int = ProtocolVersion.current) -> ControlPayload {
    .hello(HelloInfo(versions: [version], capabilities: ["connection_probe", "ping"], deviceName: "Mac"))
}
