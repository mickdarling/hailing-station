import Foundation
import HailProtocol
import Network
import Synchronization

/// Keeps one transport receive armed independently of one ordered application worker.
final class WebSocketIngressPump: Sendable {
    enum Event: Sendable {
        case application(Data)
        case control
        case terminal(String)
    }
    typealias Receive = @Sendable (@escaping @Sendable (Event) -> Void) -> Void
    typealias Process = @Sendable (Data) async -> Void
    typealias End = @Sendable (String) -> Void
    static let maxQueuedMessages = 8
    static let maxQueuedBytes = 2 * PayloadLimits.defaultMaxFrameBytes

    private struct State {
        var started = false
        var stopped = false
        var receiving = false
        var working = false
        var messages: [Data] = []
        var bytes = 0
        var worker: Task<Void, Never>?
    }
    // Only queue bookkeeping holds this lock. Lifecycle gates and callbacks run after its release.
    private let state = Mutex(State())
    private let lifecycle: ReplyTransportLifecycle
    private let receive: Receive

    init(lifecycle: ReplyTransportLifecycle, receive: @escaping Receive) {
        self.lifecycle = lifecycle
        self.receive = receive
        lifecycle.observeRetirement { [weak self] in self?.clear() }
    }

    func start(process: @escaping Process, onEnd: @escaping End) {
        let start = state.withLock { state in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        if start { arm(process: process, onEnd: onEnd) }
    }

    /// Retirement never waits for the worker, responses, or peer/router cleanup.
    func stop() {
        lifecycle.retire()
        clear()
    }

    private func clear() {
        state.withLock { state in
            state.stopped = true
            state.messages.removeAll()
            state.bytes = 0
        }
    }

    private func arm(process: @escaping Process, onEnd: @escaping End) {
        let arm = state.withLock { state in
            guard !state.stopped, !state.receiving else { return false }
            state.receiving = true
            return true
        }
        guard arm else { return }
        receive { [weak self] event in
            self?.received(event, process: process, onEnd: onEnd)
        }
    }

    private func received(_ event: Event, process: @escaping Process, onEnd: @escaping End) {
        if case .terminal(let reason) = event {
            stop()
            onEnd(reason)
            return
        }
        let decision = state.withLock { state -> (overflow: Bool, worker: Bool) in
            state.receiving = false
            guard !state.stopped else { return (false, false) }
            guard case .application(let data) = event else { return (false, false) }
            guard data.count <= PayloadLimits.defaultMaxFrameBytes,
                  state.messages.count < Self.maxQueuedMessages,
                  data.count <= Self.maxQueuedBytes - state.bytes else { return (true, false) }
            state.messages.append(data)
            state.bytes += data.count
            guard !state.working else { return (false, false) }
            state.working = true
            return (false, true)
        }
        if decision.overflow {
            stop()
            onEnd("receive queue limit")
            return
        }
        arm(process: process, onEnd: onEnd)
        if decision.worker {
            state.withLock { state in
                state.worker = Task { [self] in
                    while let data = next() { await process(data) }
                }
            }
        }
    }

    /// A snapshot for callers that explicitly join outside the peer actor and pump lock.
    var worker: Task<Void, Never>? { state.withLock { $0.worker } }

    private func next() -> Data? {
        state.withLock { state in
            guard !state.stopped, !state.messages.isEmpty else {
                state.working = false
                return nil
            }
            let data = state.messages.removeFirst()
            state.bytes -= data.count
            return data
        }
    }

    static func classify(
        _ data: Data?, context: NWConnection.ContentContext?, error: NWError?
    ) -> Event {
        if let error { return .terminal("receive failed: \(error)") }
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else { return .terminal("missing WebSocket metadata") }
        switch metadata.opcode {
        case .close: return .terminal("peer closed")
        case .ping, .pong: return .control
        case .text, .binary:
            guard let data else { return .terminal("WebSocket message had no content") }
            return .application(data)
        default: return .terminal("unsupported WebSocket message")
        }
    }
}
