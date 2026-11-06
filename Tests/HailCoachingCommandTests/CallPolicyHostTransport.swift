import Foundation
import HailProtocol
import Testing
@testable import HailCore

private enum CallPolicySocketError: Error {
    case closed
}

/// Only the receive queue, sent frames and explicit release used by the policy admission tests.
actor CallPolicySocket: WebSocketTransport {
    private var incoming: [Data] = []
    private var waiter: UnsafeContinuation<Data, any Error>?
    private var outgoing: [Data] = []
    private var closed = false

    func send(_ data: Data) {
        outgoing.append(data)
    }

    func receive() async throws -> Data {
        if closed {
            throw CallPolicySocketError.closed
        }
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        // Actor ownership gives exact-once resume and avoids the checked-continuation runtime teardown issue.
        return try await withUnsafeThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        let pending = waiter
        waiter = nil
        pending?.resume(throwing: CallPolicySocketError.closed)
    }

    func push(_ control: ControlPayload) throws {
        try push(FrameCoding.encode(Frame(timestamp: 1, source: "synthetic", payload: .control(control))))
    }

    func push(_ data: Data) {
        if let pending = waiter {
            waiter = nil
            pending.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }

    func sentFrames() throws -> [Frame] {
        try outgoing.map { try FrameCoding.decode($0) }
    }

    func selectionPing() throws -> String? {
        let frames = try sentFrames()
        guard let select = frames.firstIndex(where: {
            if case .control(.select) = $0.payload {
                return true
            }
            return false
        }) else {
            return nil
        }
        return frames.dropFirst(select).compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload {
                return nonce
            }
            return nil
        }.first
    }
}

actor CallPolicySignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private var closed = false
    var pending: Int { waiters.count }

    func wait() async {
        if closed {
            return
        }
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func releaseAll() {
        closed = true
        permits = 0
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor CallPolicyConnector: WebSocketConnecting {
    private var transport: (any WebSocketTransport)?
    private(set) var opens = 0

    func enqueue(_ transport: any WebSocketTransport) {
        self.transport = transport
    }

    func open(url: URL, subprotocol: String) throws -> any WebSocketTransport {
        opens += 1
        guard let transport else {
            throw CallPolicySocketError.closed
        }
        self.transport = nil
        return transport
    }
}

func callPolicyEventually(file: StaticString = #fileID, line: UInt = #line,
                          _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    for _ in 0..<100_000 {
        if try await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Policy fixture did not reach its signalled state at \(file):\(line)")
    throw CancellationError()
}

func callPolicyAudioFrames(_ socket: CallPolicySocket) async throws -> [Frame] {
    try await socket.sentFrames().filter {
        if case .audio = $0.payload {
            return true
        }
        return false
    }
}
