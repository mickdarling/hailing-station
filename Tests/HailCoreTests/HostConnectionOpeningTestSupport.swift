import Foundation
import HailCore

actor OpenGate {
    private var released = false
    private var waiters: [UnsafeContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withUnsafeContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor CompletionFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

actor CloseSuspendingSocket: WebSocketTransport {
    private let base: ScriptedSocket
    private let gate: OpenGate
    private(set) var closeStarted = false
    private(set) var closeStartCount = 0

    init(base: ScriptedSocket, gate: OpenGate) {
        self.base = base
        self.gate = gate
    }

    func send(_ data: Data) async throws { await base.send(data) }
    func receive() async throws -> Data { try await base.receive() }

    func close() async {
        closeStarted = true
        closeStartCount += 1
        await gate.wait()
        await base.close()
    }
}

actor SuspendingConnector: WebSocketConnecting {
    enum Step: Sendable {
        case socket(ScriptedSocket)
        case failure
    }

    private let gate: OpenGate
    private var steps: [Step]
    private(set) var openCount = 0
    private(set) var activeOpenCount = 0
    private(set) var maximumActiveOpenCount = 0

    init(gate: OpenGate, steps: [Step]) {
        self.gate = gate
        self.steps = steps
    }

    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        _ = url
        _ = subprotocol
        guard !steps.isEmpty else { throw SocketTestError.unavailable }
        let step = steps.removeFirst()
        openCount += 1
        activeOpenCount += 1
        maximumActiveOpenCount = max(maximumActiveOpenCount, activeOpenCount)
        defer { activeOpenCount -= 1 }
        await gate.wait()
        switch step {
        case .socket(let socket): return socket
        case .failure: throw SocketTestError.unavailable
        }
    }
}
