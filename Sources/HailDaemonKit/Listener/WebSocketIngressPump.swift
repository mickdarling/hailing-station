import Foundation
import HailProtocol
import Network
import Synchronization

// Queue state, classification and bounded drop reporting share one transport boundary.
// swiftlint:disable file_length

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
    static let ambientSegmentWireBytes = AmbientAudioGate.ambientSegmentWireBytes
    static let maxAudioBytes = maxQueuedAudio * ambientSegmentWireBytes
    // Allows one incoming eligible segment before eviction: 182,954 + 31 * 15,020 = 648,574.
    static let maxQueuedBytes = maxNonAudioBytes + (maxQueuedAudio + 1) * ambientSegmentWireBytes
    // Leaf lock: bookkeeping only; no decoding, callbacks, awaits or other locks.
    private let state = Mutex(State())
    private let lifecycle: ReplyTransportLifecycle
    private let receive: Receive
    private let onDrop: @Sendable (Int, ClosedRange<Int>) -> Void
    private let dropQueue = DispatchQueue(label: "hail.ingress.drops", qos: .utility)
    init(
        lifecycle: ReplyTransportLifecycle,
        onDrop: @escaping @Sendable (Int, ClosedRange<Int>) -> Void = { _, _ in },
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
        if decision.logDrops { dropQueue.async { [self] in emitDrops() } }
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
        var logDrops = false
    }
    private func enqueue(_ event: Event) -> Decision {
        // The listener callback uses its shared serial Network queue. Classification is per frame there,
        // before taking the leaf lock; protected decoded values are transient and never enter the queue.
        let message = Message.classify(event)
        return state.withLock { state in
            state.receiving = false
            guard !state.stopped, case .application = event else { return Decision() }
            guard let message, state.fits(message) else { return Decision(overflow: true) }
            var decision = Decision()
            if message.audioWindow, state.audioCount == Self.maxQueuedAudio {
                guard let index = state.messages.firstIndex(where: { $0.droppableSequence != nil }) else {
                    return Decision(overflow: true)
                }
                let removed = state.remove(at: index)
                if let sequence = removed.droppableSequence { state.recordDrop(sequence) }
                if !state.loggingDrops {
                    state.loggingDrops = true
                    decision.logDrops = true
                }
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
}
extension WebSocketIngressPump {
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
    private func emitDrops() {
        while let report = state.withLock({ state -> (Int, ClosedRange<Int>)? in
            guard let range = state.dropRange else {
                state.loggingDrops = false
                return nil
            }
            let count = state.pendingDrops
            state.pendingDrops = 0
            state.dropRange = nil
            return (count, range)
        }) {
            onDrop(report.0, report.1)
        }
    }
    /// Joins logging only when explicitly requested; transport and worker paths never wait for it.
    func waitForDropLogging() async {
        await withCheckedContinuation { continuation in
            dropQueue.async { continuation.resume() }
        }
    }

    struct Message {
        enum Retained {
            case raw(Data)
            case audio(Frame)
        }
        let retained: Retained
        let bytes: Int
        let droppableSequence: Int?
        var audioWindow: Bool { droppableSequence != nil }
        // Only the worker requests this value, after removing the message and releasing the pump lock.
        var frame: Frame? {
            switch retained {
            case .raw(let data): try? FrameCoding.decode(data)
            case .audio(let frame): frame
            }
        }
        static func classify(_ event: Event) -> Message? {
            guard case .application(let data) = event, data.count <= PayloadLimits.defaultMaxFrameBytes else {
                return nil
            }
            return Message(data)
        }
        init(_ data: Data) {
            bytes = data.count
            if data.count <= ambientSegmentWireBytes, let decoded = try? FrameCoding.decode(data),
               AmbientAudioGate.isWindowEligible(decoded, wireBytes: data.count),
               case .audio(let audio) = decoded.payload {
                retained = .audio(decoded)
                droppableSequence = audio.sequence
            } else {
                retained = .raw(data)
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
        var pendingDrops = 0
        var dropRange: ClosedRange<Int>?
        var loggingDrops = false
        func fits(_ message: Message) -> Bool {
            // The hard cap terminates before eviction; its headroom permits every eligible replacement.
            guard message.bytes <= maxQueuedBytes - bytes else { return false }
            return message.audioWindow || (nonDroppableCount < maxQueuedMessages
                && message.bytes <= maxNonAudioBytes - nonAudioBytes)
        }
        mutating func recordDrop(_ sequence: Int) {
            dropped += 1
            pendingDrops += 1
            if let range = dropRange {
                dropRange = min(range.lowerBound, sequence)...max(range.upperBound, sequence)
            } else { dropRange = sequence...sequence }
        }
        var worker: Task<Void, Never>?
        mutating func remove(at index: Int) -> Message {
            let message = messages.remove(at: index)
            bytes -= message.bytes
            if message.audioWindow { audioCount -= 1 } else { nonAudioBytes -= message.bytes }
            if message.droppableSequence == nil { nonDroppableCount -= 1 }
            return message
        }
    }
}
