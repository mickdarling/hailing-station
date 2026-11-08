import Foundation
import HailProtocol
import Network
import Synchronization

/// Keeps one transport receive armed independently of one ordered application worker.
final class WebSocketIngressPump: Sendable {
    enum Event: Sendable {
        case application(Data)
        case control
        case terminal(String, protocolError: Bool = false)
    }
    typealias Receive = @Sendable (@escaping @Sendable (Event) -> Void) -> Void
    typealias Process = @Sendable (Frame?) async -> Void
    typealias End = @Sendable (String, Bool) -> Void
    static let maxQueuedMessages = 8
    static let maxQueuedAudio = 30
    static let maxNonAudioBytes = 2 * PayloadLimits.defaultMaxFrameBytes
    static let maxAudioBytes = maxQueuedAudio * PayloadLimits.defaultMaxFrameBytes
    static let maxQueuedBytes = maxNonAudioBytes + maxAudioBytes

    private struct Message {
        let frame: Frame?
        let bytes: Int
        let audioWindow: Bool
        let droppableSequence: Int?

        // Pure, bounded classification: no callbacks or locks. Failed decoding is never droppable.
        init(_ data: Data) {
            bytes = data.count
            frame = try? FrameCoding.decode(data)
            if let frame, case .audio(let audio) = frame.payload, audio.sequence > 0 {
                audioWindow = true
                droppableSequence = audio.isFinal ? nil : audio.sequence
            } else {
                audioWindow = false
                droppableSequence = nil
            }
        }
    }
    private struct State {
        var started = false
        var stopped = false
        var receiving = false
        var working = false
        var messages: [Message] = []
        var bytes = 0
        var nonAudioBytes = 0
        var audioCount = 0
        var nonDroppableCount = 0
        var dropped = 0
        var worker: Task<Void, Never>?

        mutating func remove(at index: Int) -> Message {
            let message = messages.remove(at: index)
            bytes -= message.bytes
            if message.audioWindow { audioCount -= 1 } else { nonAudioBytes -= message.bytes }
            if message.droppableSequence == nil { nonDroppableCount -= 1 }
            return message
        }
    }
    // Leaf lock: classification and queue bookkeeping only; no callbacks, awaits or other locks.
    private let state = Mutex(State())
    private let lifecycle: ReplyTransportLifecycle
    private let receive: Receive
    private let onDrop: @Sendable (Int, Int) -> Void

    init(
        lifecycle: ReplyTransportLifecycle,
        onDrop: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        receive: @escaping Receive
    ) {
        self.lifecycle = lifecycle
        self.receive = receive
        self.onDrop = onDrop
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
            state.nonAudioBytes = 0
            state.audioCount = 0
            state.nonDroppableCount = 0
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
        if case .terminal(let reason, let protocolError) = event {
            stop()
            onEnd(reason, protocolError)
            return
        }
        let decision = enqueue(event)
        if decision.overflow {
            stop()
            onEnd("receive queue limit", false)
            return
        }
        if let sequence = decision.droppedSequence { onDrop(droppedAudioCount, sequence) }
        arm(process: process, onEnd: onEnd)
        if decision.worker {
            state.withLock { state in
                state.worker = Task { [self] in
                    while let message = next() { await process(message.frame) }
                }
            }
        }
    }

    private struct Decision {
        var overflow = false
        var worker = false
        var droppedSequence: Int?
    }

    private func enqueue(_ event: Event) -> Decision {
        state.withLock { state in
            state.receiving = false
            guard !state.stopped, case .application(let data) = event else { return Decision() }
            guard data.count <= PayloadLimits.defaultMaxFrameBytes else { return Decision(overflow: true) }
            let message = Message(data)
            // The aggregate cap terminates before eviction; it is never converted into a drop policy.
            guard data.count <= Self.maxQueuedBytes - state.bytes else { return Decision(overflow: true) }
            if message.droppableSequence == nil, state.nonDroppableCount == Self.maxQueuedMessages {
                return Decision(overflow: true)
            }
            if !message.audioWindow, data.count > Self.maxNonAudioBytes - state.nonAudioBytes {
                return Decision(overflow: true)
            }
            var decision = Decision()
            if message.audioWindow, state.audioCount == Self.maxQueuedAudio {
                guard let index = state.messages.firstIndex(where: { $0.droppableSequence != nil }) else {
                    return Decision(overflow: true)
                }
                decision.droppedSequence = state.remove(at: index).droppableSequence
                state.dropped += 1
            }
            state.messages.append(message)
            state.bytes += message.bytes
            if message.audioWindow { state.audioCount += 1 } else { state.nonAudioBytes += message.bytes }
            if message.droppableSequence == nil { state.nonDroppableCount += 1 }
            if !state.working {
                state.working = true
                decision.worker = true
            }
            return decision
        }
    }

    var droppedAudioCount: Int { state.withLock { $0.dropped } }
    /// A snapshot for callers that explicitly join outside the peer actor and pump lock.
    var worker: Task<Void, Never>? { state.withLock { $0.worker } }

    private func next() -> Message? {
        state.withLock { state in
            guard !state.stopped, !state.messages.isEmpty else {
                state.working = false
                return nil
            }
            return state.remove(at: 0)
        }
    }

    static func classify(
        _ data: Data?, context: NWConnection.ContentContext?, error: NWError?
    ) -> Event {
        if let error { return .terminal("receive failed: \(error)") }
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else {
            return .terminal("missing WebSocket metadata", protocolError: true)
        }
        switch metadata.opcode {
        case .close: return .terminal("peer closed")
        case .ping, .pong: return .control
        case .text, .binary:
            guard let data else { return .terminal("WebSocket message had no content", protocolError: true) }
            return .application(data)
        default: return .terminal("unsupported WebSocket message", protocolError: true)
        }
    }
}
