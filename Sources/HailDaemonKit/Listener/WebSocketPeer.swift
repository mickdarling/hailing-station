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

// Lifecycle retirement and protocol closure remain one peer boundary.
// swiftlint:disable type_body_length
/// One socket and one `HostSession`; receive calls are serialized per peer while different peers progress
/// independently. The parent listener owns bounded admission and shutdown.
actor WebSocketPeer {
    typealias ReplySender = @Sendable (@escaping @Sendable (NWError?) -> Void) -> Void
    private let id: UUID
    private let connection: NWConnection
    let session: HostSession
    private let queue: DispatchQueue
    private let helloTimeout: Duration
    private let log: @Sendable (WebSocketListenerEvent) -> Void
    private let onEnd: @Sendable (UUID) -> Void
    private var helloTimer: Task<Void, Never>?
    private let replyTransport = ReplyTransportLifecycle()
    private let submitClose: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let submitReply: ReplySender?
    private var closing = false
    var ended = false

    init(
        id: UUID, connection: NWConnection, session: HostSession, queue: DispatchQueue,
        helloTimeout: Duration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void,
        onEnd: @escaping @Sendable (UUID) -> Void,
        submitClose: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil,
        submitReply: ReplySender? = nil
    ) {
        self.id = id
        self.connection = connection
        self.session = session
        self.queue = queue
        self.helloTimeout = helloTimeout
        self.log = log
        self.onEnd = onEnd
        self.submitReply = submitReply
        self.submitClose = submitClose ?? { completion in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.protocolError)
            let context = NWConnection.ContentContext(identifier: "hail.close", isFinal: true, metadata: [metadata])
            connection.send(
                content: nil, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in completion() }
            )
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self, replyTransport] state in
            switch state {
            case .failed, .cancelled: replyTransport.retire()
            default: break
            }
            Task { await self?.connectionChanged(state) }
        }
        startHelloTimer()
        connection.start(queue: queue)
    }

    func stop(reason: String) { finish(reason: reason) }

    /// This peer's own lifecycle only: not ended, not closing, transport not retired. A caller's task
    /// cancellation is never this peer's state, so it cannot make a live peer look gone (#188 dispatch).
    var isLive: Bool { !ended && !closing && !replyTransport.isRetired }

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
        guard !ended, !closing else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { await self?.received(data, context: context, error: error) }
        }
    }

    private func received(
        _ data: Data?, context: NWConnection.ContentContext?, error: NWError?
    ) async {
        guard !ended, !closing else { return }
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
        guard !ended, !closing else { return }
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

    func close(reason: String) async {
        guard !ended, !closing else { return }
        closing = true
        // Refuse reply publication before the close frame is submitted, not after its completion.
        replyTransport.retire()
        await withCheckedContinuation { continuation in
            submitClose { continuation.resume() }
        }
        finish(reason: reason)
    }

    func finish(reason: String) {
        guard !ended else { return }
        // Complete invalidation before closure returns. Previously prepared replies cannot enqueue later.
        replyTransport.retire()
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
// swiftlint:enable type_body_length

extension WebSocketPeer {
    /// Preparation is not an enqueue grant; its transport permit must remain current at final admission.
    func prepareReplyPublication(
        _ frame: Frame, onLateSuccess: (@Sendable () -> Void)? = nil
    ) -> PreparedWebSocketReply? {
        guard !ended, !closing, !Task.isCancelled, let data = try? FrameCoding.encode(frame),
              let permit = replyTransport.issuePermit() else { return nil }
        // Synthetic completion control; all production and injected sends retain the same final transport gate.
        if let submitReply {
            return PreparedWebSocketReply(
                permit: permit, submit: submitReply, onLateSuccess: onLateSuccess, cancel: { [weak self] reason in
                    Task { await self?.finish(reason: reason) }
                }
            )
        }
        return PreparedWebSocketReply(
            data: data, connection: connection, permit: permit, onLateSuccess: onLateSuccess
        ) { [weak self] reason in
            Task { await self?.finish(reason: reason) }
        }
    }

    /// Abandonment is a refused, ambiguous publication, while the enqueued bytes retain their wire order.
    func replySendSucceeded(_ outcome: PreparedWebSocketReply.Outcome) -> Bool {
        switch outcome {
        case .sent: return true
        case .failed(let error): finish(reason: "host reply send failed: \(error)")
        case .abandoned: emit("host_reply_send_abandoned", detail: "caller cancelled after enqueue")
        case .refused: break
        }
        return false
    }

    func send(_ frame: Frame) async -> Bool {
        guard !ended, !closing, !Task.isCancelled else { return false }
        guard let data = try? FrameCoding.encode(frame), let permit = replyTransport.issuePermit() else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let submitted = permit.performIfCurrent {
                    connection.send(
                        content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { continuation.resume(returning: $0 == nil) }
                    )
                    return true
                } ?? false
                if !submitted { continuation.resume(returning: false) }
            }
        } onCancel: { [replyTransport, connection] in
            replyTransport.retire()
            connection.cancel()
        }
    }

    /// Queues `frame` on the connection and returns without waiting for it to go out (#318 review): a stalled peer
    /// cannot hold the caller up, and whatever the connection is given later still goes out after it.
    func post(_ frame: Frame) -> Bool {
        guard !ended, !closing, let data = try? FrameCoding.encode(frame),
              let permit = replyTransport.issuePermit() else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
        return permit.performIfCurrent {
            connection.send(
                content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in }
            )
            return true
        } ?? false
    }
}

/// One peer's terminal lifecycle. Unlike restorable policy authority, retired transport never reopens.
/// Preparation and submission share this lock; revision rotation cannot issue a fresh usable ticket.
final class ReplyTransportLifecycle: Sendable {
    private let retired = Mutex(false)
    private let authority = ReplyPublicationAuthority()

    func issuePermit() -> ReplyTransportPermit? {
        retired.withLock { retired in
            guard !retired else { return nil }
            return ReplyTransportPermit(lifecycle: self, permit: authority.issuePermit())
        }
    }

    func retire() {
        retired.withLock { retired in
            guard !retired else { return }
            retired = true
            authority.invalidate()
        }
    }

    var isRetired: Bool { retired.withLock { $0 } }

    fileprivate func performIfCurrent<Result: Sendable>(
        _ permit: ReplyPublicationPermit, operation: () throws -> Result
    ) rethrows -> Result? {
        try retired.withLock { retired in
            guard !retired else { return nil }
            return try permit.performIfCurrent(operation)
        }
    }
}

/// Immutable peer-scoped transport evidence; no cached active Boolean escapes to a later enqueue.
struct ReplyTransportPermit: Sendable {
    private let lifecycle: ReplyTransportLifecycle
    private let permit: ReplyPublicationPermit

    fileprivate init(lifecycle: ReplyTransportLifecycle, permit: ReplyPublicationPermit) {
        self.lifecycle = lifecycle
        self.permit = permit
    }

    func performIfCurrent<Result: Sendable>(_ operation: () throws -> Result) rethrows -> Result? {
        try lifecycle.performIfCurrent(permit, operation: operation)
    }

    func retireTransport() { lifecycle.retire() }
}

/// Immutable transport submission. HostSession supplies the policy/binding/local-state critical section;
/// this final gate additionally orders peer closure against the actual Network enqueue, not completion.
final class PreparedWebSocketReply: Sendable {
    enum Outcome: Equatable, Sendable {
        case sent
        case failed(String)
        case abandoned
        case refused
    }
    /// Extra time after the caller gives up, not a replacement for the local submission deadline.
    static let abandonedSendGrace: Duration = .seconds(30)

    private final class WaiterOwner: Sendable {}
    private struct State {
        var submitted = false
        var transportCompleted = false
        var outcome: Outcome?
        var waiter: CheckedContinuation<Outcome, Never>?
        var waiterOwner: WaiterOwner?
        var watchdog: Task<Void, Never>?
    }
    private struct Completion {
        let waiter: CheckedContinuation<Outcome, Never>?
        let watchdog: Task<Void, Never>?
        let lateSuccess: Bool
    }
    private let state = Mutex(State())
    private let permit: ReplyTransportPermit
    private let submit: @Sendable (@escaping @Sendable (NWError?) -> Void) -> Void
    private let cancel: @Sendable (String) -> Void
    /// Completion-queue callback, outside the state lock, only for an abandoned send's first success.
    private let onLateSuccess: (@Sendable () -> Void)?
    private let waiterAdmitted: @Sendable () -> Void
    private let stallGrace: Duration

    convenience init(
        data: Data, connection: NWConnection, permit: ReplyTransportPermit,
        onLateSuccess: (@Sendable () -> Void)? = nil, cancel: @escaping @Sendable (String) -> Void
    ) {
        self.init(permit: permit, submit: { completion in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { completion($0) }
            )
        }, onLateSuccess: onLateSuccess, cancel: cancel)
    }

    /// Internal DI keeps lifecycle tests synthetic; only WebSocketPeer supplies production transport.
    init(
        permit: ReplyTransportPermit,
        submit: @escaping @Sendable (@escaping @Sendable (NWError?) -> Void) -> Void,
        onLateSuccess: (@Sendable () -> Void)? = nil,
        cancel: @escaping @Sendable (String) -> Void = { _ in },
        waiterAdmitted: @escaping @Sendable () -> Void = {},
        stallGrace: Duration = PreparedWebSocketReply.abandonedSendGrace
    ) {
        self.permit = permit
        self.submit = submit
        self.cancel = cancel
        self.onLateSuccess = onLateSuccess
        self.waiterAdmitted = waiterAdmitted
        self.stallGrace = stallGrace
    }

    /// Success is enqueue only; result() receives the later outcome. Never await completion under a gate.
    func enqueue() -> Bool {
        let enqueued = permit.performIfCurrent {
            guard !Task.isCancelled, state.withLock({ state in
                guard !state.submitted, state.outcome == nil else { return false }
                state.submitted = true
                return true
            }) else { return false }
            submit { [self] error in complete(error) }
            return true
        } ?? false
        if !enqueued {
            let waiter = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
                guard !state.submitted, state.outcome == nil else { return nil }
                state.outcome = .refused
                let waiter = state.waiter
                state.waiter = nil
                state.waiterOwner = nil
                return waiter
            }
            waiter?.resume(returning: .refused)
        }
        return enqueued
    }

    /// One pending waiter; a second concurrent waiter refuses without disturbing the legitimate owner.
    func result() async -> Outcome {
        let owner = WaiterOwner()
        let immediate = state.withLock { state -> Outcome? in
            if let outcome = state.outcome { return outcome }
            guard state.waiterOwner == nil else { return .refused }
            state.waiterOwner = owner
            return nil
        }
        if let immediate { return immediate }
        waiterAdmitted()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Outcome? in
                    if let outcome = state.outcome { return outcome }
                    state.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: { [self] in cancelResult(owner) }
    }

    private func cancelResult(_ owner: WaiterOwner) {
        let result = state.withLock { state -> (Outcome, CheckedContinuation<Outcome, Never>?)? in
            guard state.outcome == nil, owner === state.waiterOwner else { return nil }
            let outcome: Outcome = state.submitted ? .abandoned : .refused
            state.outcome = outcome
            if state.submitted {
                state.watchdog = Task { [weak self, stallGrace] in
                    do { try await Task.sleep(for: stallGrace) } catch { return }
                    self?.expireAbandonedSend()
                }
            }
            let waiter = state.waiter
            state.waiter = nil
            state.waiterOwner = nil
            return (outcome, waiter)
        }
        if let result { result.1?.resume(returning: result.0) }
    }
}

private extension PreparedWebSocketReply {
    func complete(_ error: NWError?) {
        let outcome: Outcome = error.map { .failed(String(describing: $0)) } ?? .sent
        let result = state.withLock { state -> Completion? in
            guard !state.transportCompleted else { return nil }
            state.transportCompleted = true
            let watchdog = state.watchdog
            state.watchdog = nil
            let waiter = state.waiter
            state.waiter = nil
            state.waiterOwner = nil
            let lateSuccess = state.outcome == .abandoned && error == nil
            if state.outcome == nil { state.outcome = outcome }
            return Completion(waiter: waiter, watchdog: watchdog, lateSuccess: lateSuccess)
        }
        guard let result else { return }
        result.watchdog?.cancel()
        // Call the Sendable observer only after releasing the ticket's state lock.
        if result.lateSuccess { onLateSuccess?() }
        if case .failed(let description) = outcome {
            // A synthetic sender may complete inline under the transport gate. Retire off that stack.
            Task { [self] in closeTransport(reason: "host reply send failed: \(description)") }
        }
        result.waiter?.resume(returning: outcome)
    }

    func expireAbandonedSend() {
        let expired = state.withLock { state in
            guard !state.transportCompleted else { return false }
            state.transportCompleted = true
            state.watchdog = nil
            return true
        }
        if expired { closeTransport(reason: "host reply send stalled") }
    }

    func closeTransport(reason: String) {
        permit.retireTransport()
        cancel(reason)
    }
}
