import Foundation
import Network
import HailProtocol
import Synchronization

// Peer lifecycle and its prepared enqueue/completion ticket share one bounded transport boundary.
// swiftlint:disable file_length

func parseBindAddress(_ address: String) -> (host: NWEndpoint.Host, canonical: String)? {
    if let ipv4 = IPv4Address(address), !ipv4.rawValue.allSatisfy({ $0 == 0 }) {
        return (.ipv4(ipv4), "\(ipv4)")
    }
    if let ipv6 = IPv6Address(address) {
        let raw = ipv6.rawValue
        let mappedIPv4 = raw.prefix(10).allSatisfy { $0 == 0 }
            && raw.dropFirst(10).prefix(2).allSatisfy { $0 == 0xff }
        if !raw.allSatisfy({ $0 == 0 }), !mappedIPv4 { return (.ipv6(ipv6), "\(ipv6)") }
    }
    return nil
}

/// One socket and one `HostSession`; receive calls are serialized per peer while different peers progress
/// independently. The parent listener owns bounded admission and shutdown.
actor WebSocketPeer {
    private let id: UUID
    private let connection: NWConnection
    let session: HostSession
    private let queue: DispatchQueue
    private let helloTimeout: Duration
    private let log: @Sendable (WebSocketListenerEvent) -> Void
    private let onEnd: @Sendable (UUID) -> Void
    private var helloTimer: Task<Void, Never>?
    private let replyAuthority = ReplyPublicationAuthority()
    var ended = false

    init(
        id: UUID, connection: NWConnection, session: HostSession, queue: DispatchQueue,
        helloTimeout: Duration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void,
        onEnd: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.session = session
        self.queue = queue
        self.helloTimeout = helloTimeout
        self.log = log
        self.onEnd = onEnd
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.connectionChanged(state) }
        }
        startHelloTimer()
        connection.start(queue: queue)
    }

    func stop(reason: String) { finish(reason: reason) }

    private func connectionChanged(_ state: NWConnection.State) {
        guard !ended else { return }
        switch state {
        case .ready:
            emit("session_connected", endpoint: "\(connection.endpoint)")
            receiveNext()
        case .failed(let error): finish(reason: "failed: \(error)")
        case .cancelled: finish(reason: "cancelled")
        case .waiting(let error): emit("session_waiting", detail: "\(error)")
        case .setup, .preparing: break
        @unknown default: finish(reason: "unknown state")
        }
    }

    private func startHelloTimer() {
        helloTimer = Task { [weak self, helloTimeout] in
            do {
                try await Task.sleep(for: helloTimeout)
            } catch {
                return
            }
            await self?.helloTimedOut()
        }
    }

    private func helloTimedOut() {
        guard helloTimer != nil else { return }
        finish(reason: "hello timeout")
    }

    private func receiveNext() {
        guard !ended else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { await self?.received(data, context: context, error: error) }
        }
    }

    private func received(
        _ data: Data?, context: NWConnection.ContentContext?, error: NWError?
    ) async {
        guard !ended else { return }
        if let error {
            finish(reason: "receive failed: \(error)")
            return
        }
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else {
            await close(reason: "missing WebSocket metadata")
            return
        }
        switch metadata.opcode {
        case .close:
            finish(reason: "peer closed")
        case .ping, .pong:
            receiveNext()
        case .text, .binary:
            guard let data else {
                await close(reason: "WebSocket message had no content")
                return
            }
            await process(data)
        default:
            await close(reason: "unsupported WebSocket message")
        }
    }

    private func process(_ data: Data) async {
        let result = await session.receive(data)
        if result.frames.contains(where: { frame in
            if case .control(.hello) = frame.payload { return true }
            return false
        }) {
            helloTimer?.cancel()
            helloTimer = nil
        }
        for frame in result.frames {
            guard await send(frame) else {
                finish(reason: "send failed")
                return
            }
        }
        guard !ended else { return }
        switch result.disposition {
        case .keepOpen: receiveNext()
        case .close: await close(reason: "protocol closed")
        }
    }

    private func close(reason: String) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.protocolError)
        let context = NWConnection.ContentContext(identifier: "hail.close", isFinal: true, metadata: [metadata])
        await withCheckedContinuation { continuation in
            connection.send(
                content: nil, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
        finish(reason: reason)
    }

    func finish(reason: String) {
        guard !ended else { return }
        // Complete invalidation before closure returns. Previously prepared replies cannot enqueue later.
        replyAuthority.invalidate()
        ended = true
        helloTimer?.cancel()
        helloTimer = nil
        connection.cancel()
        emit("session_disconnected", detail: reason)
        onEnd(id)
    }

    private func emit(_ event: String, endpoint: String? = nil, detail: String? = nil) {
        log(WebSocketListenerEvent(event: event, sessionID: id, endpoint: endpoint, detail: detail))
    }
}

extension WebSocketPeer {
    /// Preparation is not an enqueue grant; its transport permit must remain current at final admission.
    func prepareReplyPublication(_ frame: Frame) -> PreparedWebSocketReply? {
        guard !ended, !Task.isCancelled, let data = try? FrameCoding.encode(frame) else { return nil }
        return PreparedWebSocketReply(data: data, connection: connection, authority: replyAuthority)
    }

    func send(_ frame: Frame) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let data = try? FrameCoding.encode(frame) else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connection.send(
                    content: data, contentContext: context, isComplete: true,
                    completion: .contentProcessed { continuation.resume(returning: $0 == nil) }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Immutable transport submission. HostSession supplies the policy/binding/local-state critical section;
/// this final gate additionally orders peer closure against the actual Network enqueue, not completion.
final class PreparedWebSocketReply: Sendable {
    private enum Completion {
        case pending
        case finished(Bool)
    }
    private struct State {
        var submitted = false
        var completion = Completion.pending
        var waiter: CheckedContinuation<Bool, Never>?
    }
    private let state = Mutex(State())
    private let permit: ReplyPublicationPermit
    private let submit: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    private let cancel: @Sendable () -> Void

    convenience init(data: Data, connection: NWConnection, authority: ReplyPublicationAuthority) {
        self.init(permit: authority.issuePermit(), submit: { completion in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { completion($0 == nil) }
            )
        }, cancel: { authority.invalidate(); connection.cancel() })
    }

    /// Internal DI keeps lifecycle tests synthetic; only WebSocketPeer supplies production transport.
    init(
        permit: ReplyPublicationPermit,
        submit: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.permit = permit
        self.submit = submit
        self.cancel = cancel
    }

    /// Returns false without submission when stale, cancelled or already submitted. Success is enqueue
    /// only; result() receives the later transport outcome. Never await completion while holding a gate.
    func enqueue() -> Bool {
        let enqueued = permit.performIfCurrent {
            guard !Task.isCancelled, state.withLock({ state in
                guard !state.submitted, case .pending = state.completion else { return false }
                state.submitted = true
                return true
            }) else { return false }
            submit { [self] result in _ = finish(result) }
            return true
        } ?? false
        if !enqueued { _ = finish(false, onlyIfUnsubmitted: true) }
        return enqueued
    }

    /// One pending waiter, with completion buffered if it arrives first. Later completed reads are safe;
    /// a second concurrent waiter fails closed rather than replacing or leaking the original continuation.
    func result() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Completion in
                    if case .finished = state.completion { return state.completion }
                    guard state.waiter == nil else { return .finished(false) }
                    state.waiter = continuation
                    return .pending
                }
                if case .finished(let result) = immediate { continuation.resume(returning: result) }
            }
        } onCancel: { [self] in
            if finish(false) { cancel() }
        }
    }

    @discardableResult
    private func finish(_ result: Bool, onlyIfUnsubmitted: Bool = false) -> Bool {
        let outcome = state.withLock { state -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard case .pending = state.completion, !onlyIfUnsubmitted || !state.submitted else { return (false, nil) }
            state.completion = .finished(result)
            let waiter = state.waiter
            state.waiter = nil
            return (true, waiter)
        }
        outcome.1?.resume(returning: result)
        return outcome.0
    }
}
