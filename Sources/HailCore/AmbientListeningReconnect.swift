// swiftlint:disable file_length
// The restore coordinator and its generation-bound privacy confirmation share the same lifetime and guards.
public import Foundation
import HailProtocol
import OSLog
public import Observation
import Synchronization

/// Production waits call `Task.sleep(for:)` directly; only tests inject `sleep`. Calling a stored closure-literal
/// sleep default from a Task aborted ("freed pointer was not the last allocation") on the macOS 15 runtime (#904).
func ambientSleep(for duration: Duration, injected sleep: (@Sendable (Duration) async throws -> Void)?) async throws {
    guard let sleep else { return try await Task.sleep(for: duration) }
    try await sleep(duration)
}

/// Device-side confirmation for the retained capture. A host notice is never an owner veto.
@MainActor
final class AmbientRestorePrivacy {
    var sleep: (@Sendable (Duration) async throws -> Void)?
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    private var waiting: AmbientAudioBinding?
    private var began: ContinuousClock.Instant?
    private var requested = false
    private var sent = false
    private var confirmed = false
    private var completion: (@MainActor (Bool) -> Void)?
    private var timeout: Task<Void, Never>?
    private var send: Task<Void, Never>?

    func begin(_ binding: AmbientAudioBinding, store: HostConnectionStore,
               completion: @escaping @MainActor (Bool) -> Void) {
        guard waiting != binding else { return }
        cancel()
        waiting = binding
        began = now()
        self.completion = completion
        // Today's hosts ignore no-stream privacy: fail closed in 5 s. Private restoration depends on a host
        // per-connection pre-arm that confirms duck_mode on and starts the next stream private (or its parked state).
        timeout = Task { [weak self, sleep] in
            guard (try? await ambientSleep(for: .seconds(5), injected: sleep)) != nil, !Task.isCancelled else { return }
            self?.finish(false, binding: binding)
        }
        send = Task { [weak self, weak store] in
            guard !Task.isCancelled, self?.waiting == binding else { return }
            self?.requested = true
            do {
                guard let store else { throw CancellationError() }
                try await store.reassertPrivacy(for: binding)
                guard self?.waiting == binding else { return }
                self?.sent = true
                self?.completeIfReady(binding)
            } catch { self?.finish(false, binding: binding) }
        }
    }

    func receive(on: Bool, snapshot: HostConnectionSnapshot) {
        guard snapshot.state == .ready else { return }
        receive(on: on, host: snapshot.id, generation: snapshot.connectionGeneration)
    }

    func receive(on: Bool, host: HostEndpoint.Identifier, generation: UUID?) {
        guard requested, let waiting, waiting.hostID == host,
              waiting.connectionGeneration == generation, let began else { return }
        let elapsed: Duration = now() - began
        guard on, elapsed < .seconds(5) else { return finish(false, binding: waiting) }
        confirmed = true
        completeIfReady(waiting)
    }

    private func completeIfReady(_ binding: AmbientAudioBinding) {
        guard sent, confirmed, let began else { return }
        // An early notice is only half the proof: never cancel an outstanding send that may still fail.
        let elapsed: Duration = now() - began
        finish(elapsed < .seconds(5), binding: binding)
    }

    func sendFailed(host: HostEndpoint.Identifier, generation: UUID) -> Bool {
        guard requested, let waiting, waiting.hostID == host, waiting.connectionGeneration == generation else {
            return false
        }
        finish(false, binding: waiting)
        return true
    }

    private func finish(_ confirmed: Bool, binding: AmbientAudioBinding) {
        guard waiting == binding else { return }
        let completed = completion
        cancel()
        completed?(confirmed)
    }

    func cancel() {
        waiting = nil
        requested = false
        sent = false
        confirmed = false
        began = nil
        completion = nil
        timeout?.cancel()
        timeout = nil
        send?.cancel()
        send = nil
    }
}

/// One run's transport recovery (#904). Reassert known privacy; keep owner vetoes latched.
@MainActor
@Observable
public final class AmbientListeningReconnect {
    public enum Reason: Int64, Sendable {
        case ownerStop = 1, ownerSelection, endpointChanged, explicitDisconnect, privacy, modeChanged
        case bindingChanged, targetChanged, startFailed, nonTransport, timedOut, movedAway, reauthorizationNeeded
    }
    public enum Outcome: Sendable { case applied, blocked, failed, interrupted }
    public struct Notice: Equatable, Sendable {
        public let id: UUID
        public let outcome: Outcome
        public let reason: Reason?
        init(id: UUID = UUID(), outcome: Outcome, reason: Reason?) {
            self.id = id
            self.outcome = outcome
            self.reason = reason
        }
        public var notificationTitle: String {
            if outcome == .interrupted { return "Hailing Station reconnecting" }
            return outcome == .applied ? "Hailing Station reconnected" : "Hailing Station stopped listening"
        }
        public var text: String {
            if reason == .reauthorizationNeeded {
                return "Listening stopped; re-authorization needed. Choose a destination to continue."
            }
            if outcome == .interrupted { return "Connection dropped again; still reconnecting" }
            return outcome == .applied ? "Connection dropped and reconnected; listening resumed"
                : "Connection dropped; listening stopped, tap to resume"
        }
    }
    public private(set) var binding: AmbientAudioBinding?
    public private(set) var hostName: String?
    public private(set) var notice: Notice?
    @ObservationIgnored public var onNotice: (@MainActor (Notice) -> Void)?
    @ObservationIgnored weak var controller: AmbientListeningController?
    @ObservationIgnored var sleep: (@Sendable (Duration) async throws -> Void)?
    @ObservationIgnored var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    @ObservationIgnored let privacyConfirmation = AmbientRestorePrivacy()
    private(set) var acceptance: AmbientResumeAcceptance?
    @ObservationIgnored private var acceptanceTask: Task<Void, Never>?
    private var pending: Pending?
    private var veto: Reason?
    private var renewed = false
    private(set) var replacedAppliedNotice = false
    private var selectionGeneration: UUID?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private struct Pending {
        let id = UUID()
        let droppedGeneration: UUID
        var endpoint: HostEndpoint
        let binding: AmbientAudioBinding
        let target: TargetInfo?
        let began: ContinuousClock.Instant
        var privateBeforeDrop: Bool
    }
    public init() {}
    public var isPending: Bool { pending != nil }
    public var wantsListening: Bool { isPending }
    var isReauthorizing: Bool { isPending && !renewed && selectionGeneration != nil }
    func ownerStarted() {
        veto = nil; notice = nil; replacedAppliedNotice = false
        cancelAcceptance()
    }
    func block(_ reason: Reason) {
        veto = veto ?? reason // Includes a privacy tap before the receive loop publishes the close, even if send fails.
        cancelAcceptance()
        guard isPending else { return }
        finish(.blocked, reason: veto)
        controller?.cancelTransportRestore()
    }
    func drop(_ snapshot: HostConnectionSnapshot, store: HostConnectionStore) {
        guard let controller, controller.isListening, let current = controller.binding,
              current.hostID == snapshot.id else { return }
        // A send failure and the receive loop may report the SAME drop. Only a different socket is a flap.
        guard pending?.droppedGeneration != snapshot.connectionGeneration else { return }
        cancelAcceptance()
        controller.suspendTransport() // Every gap closes admission, including a renewed stream with no PCM yet.
        let interrupted = pending
        // Flapping: each interrupted attempt ends once as interrupted; the next drop owns a new attempt and notice.
        // All attempts in this unsettled run share the ORIGINAL 60 s bound; a flap never buys more capture time.
        if interrupted != nil { finish(.interrupted, reason: .startFailed) }
        binding = current
        hostName = snapshot.endpoint.name
        if interrupted == nil { notice = nil }
        renewed = false
        replacedAppliedNotice = false
        selectionGeneration = nil
        let began = interrupted?.began ?? now()
        pending = Pending(droppedGeneration: snapshot.connectionGeneration,
                          endpoint: snapshot.endpoint, binding: current,
                          target: interrupted?.target ?? snapshot.targets.first { $0.id == current.targetID },
                          began: began,
                          privateBeforeDrop: interrupted?.privateBeforeDrop == true
                              || store.duckMode[snapshot.id]?.isOn() == true)
        if let veto { return block(veto) }
        if store.privacyLocal[snapshot.id]?.request != nil { return block(.privacy) }
        guard withinDeadline() else { return }
        let elapsed: Duration = now() - began
        armDeadline(interrupted == nil ? .seconds(60) : .seconds(60) - elapsed)
    }
    private func armDeadline(_ remaining: Duration) {
        deadline = Task { [weak self, sleep] in
            guard (try? await ambientSleep(for: remaining, injected: sleep)) != nil, !Task.isCancelled else { return }
            self?.block(.timedOut)
        }
    }

    func finish(_ outcome: Outcome, reason: Reason?) {
        guard let pending else { return }
        self.pending = nil
        privacyConfirmation.cancel()
        deadline?.cancel()
        deadline = nil
        notice = Notice(outcome: outcome, reason: reason)
        let elapsed = pending.began.duration(to: now()).components
        controller?.diagnostics?.record(.captureState, [
            .state: .token("reconnecting"), .on: .boolean(outcome == .applied),
            .error: .integer(reason?.rawValue ?? 0), .code: .token(outcome == .failed ? "resume_failed" : "other"),
            .ms: .integer(max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
        ])
        if let token = reason?.diagnosticToken {
            Logger(subsystem: "com.mickdarling.hailing-station", category: "ambient-restore")
                .notice("\(token, privacy: .public)")
        }
        if let notice { onNotice?(notice) }
    }
}

extension AmbientListeningReconnect {
    func receive(_ snapshot: HostConnectionSnapshot, previous: HostConnectionSnapshot?, store: HostConnectionStore) {
        recordDrop(snapshot, previous: previous, store: store)
        guard let intent = pending, intent.binding.hostID == snapshot.id else { return }
        if case .failed = snapshot.state { return block(.nonTransport) }
        if snapshot.state == .disconnected { return block(.explicitDisconnect) }
        if snapshot.endpoint != intent.endpoint { return block(.endpointChanged) }
        guard snapshot.state == .ready, snapshot.receivedTargetList else { return }
        if !snapshot.capabilities.contains(HostConnection.streamAudioCapability) { return block(.bindingChanged) }
        if !snapshot.targets.contains(where: { $0 == intent.target && $0.alive }) { return block(.targetChanged) }
        reauthorize(snapshot, intent: intent, store: store)
    }
    private func recordDrop(_ snapshot: HostConnectionSnapshot, previous: HostConnectionSnapshot?,
                            store: HostConnectionStore) {
        if previous?.state == .ready, let previous {
            switch snapshot.state {
            case .reconnecting, .connecting: drop(previous, store: store)
            default: break // Protocol failures and explicit disconnects never arm recovery.
            }
        }
    }
    private func reauthorize(_ snapshot: HostConnectionSnapshot, intent: Pending, store: HostConnectionStore) {
        guard snapshot.connectionGeneration != intent.binding.connectionGeneration,
              selectionGeneration != snapshot.connectionGeneration else { return }
        selectionGeneration = snapshot.connectionGeneration
        // Background recovery cannot depend on the foreground-only remembered-selection view task.
        Task { [weak self, weak store] in
            guard let self, let store, self.pending?.id == intent.id,
                  self.selectionGeneration == snapshot.connectionGeneration,
                  store.snapshots[snapshot.id]?.connectionGeneration == snapshot.connectionGeneration else { return }
            try? await store.selectTarget(host: snapshot.id, targetID: intent.binding.targetID, restoring: true)
        }
    }
    /// Reauthorize the same selection on a new generation. No fresh capture start or foreground requirement.
    func restore(store: HostConnectionStore) {
        guard let intent = pending, !renewed,
              let current = store.ambientBinding(host: intent.binding.hostID, targetID: intent.binding.targetID),
              current.connectionGeneration != intent.binding.connectionGeneration else { return }
        guard withinDeadline() else { return }
        guard current.selection == intent.binding.selection,
              store.snapshots[current.hostID]?.endpoint == intent.endpoint else { return block(.bindingChanged) }
        if store.privacyLocal[current.hostID]?.request != nil {
            return block(.privacy)
        }
        if intent.privateBeforeDrop {
            privacyConfirmation.sleep = sleep
            privacyConfirmation.now = now
            privacyConfirmation.begin(current, store: store) { [weak self, weak store] confirmed in
                guard let self, let store, self.pending?.id == intent.id, !self.renewed else { return }
                guard confirmed else {
                    self.finish(.failed, reason: .privacy)
                    self.controller?.cancelTransportRestore()
                    return
                }
                guard store.ambientBinding(host: current.hostID, targetID: current.targetID) == current,
                      self.withinDeadline() else { return }
                self.resume(current)
            }
        } else { resume(current) }
    }
    private func resume(_ current: AmbientAudioBinding) {
        guard let controller else { return }
        renewed = true // Host notices after this are normal listening state, never an owner action during the gap.
        binding = current
        if !controller.restoreTransport(current) {
            finish(.failed, reason: .startFailed)
            controller.cancelTransportRestore()
        }
    }
    // Ambient has no positive host acceptance acknowledgement. A later refusal revises the same outcome
    // only for the restored stream before its post-segment round trip proves the host kept listening.
    func refused(reason: Reason, streamID: UUID?, binding: AmbientAudioBinding?) {
        guard let previous = notice, previous.outcome == .applied, renewed,
              let acceptance, acceptance.streamID == streamID, acceptance.binding == binding else { return }
        let elapsed: Duration = now() - acceptance.began
        guard elapsed < .seconds(60) else { cancelAcceptance(); return }
        replacedAppliedNotice = true
        notice = Notice(id: previous.id, outcome: .failed, reason: reason)
        cancelAcceptance()
        if let notice { onNotice?(notice) }
    }
    func sent(_ audio: AudioPayload) {
        if isPending, renewed, audio.isResume, withinDeadline() { finish(.applied, reason: nil) }
    }
    func withinDeadline() -> Bool {
        guard let pending else { return true }
        let elapsed: Duration = now() - pending.began
        if elapsed >= .seconds(60) { block(.timedOut); return false }
        return true
    }
    func sendFailed(_ error: any Error, audio: AudioPayload, binding: AmbientAudioBinding,
                    store: HostConnectionStore) {
        guard !(error is CancellationError), !(error is EncodingError),
              !(error is HostConnectionFailure) || (error as? HostConnectionFailure) == .notReady,
              controller?.ownsAudio(audio.streamID, binding: binding) == true,
              let snapshot = store.snapshots[binding.hostID],
              snapshot.connectionGeneration == binding.connectionGeneration else { return }
        drop(snapshot, store: store)
    }
    func veto(_ reason: Reason, host: HostEndpoint.Identifier) {
        // A completed restore retains presentation state, but only a pending restore owns this run's veto.
        if controller?.binding?.hostID == host || (isPending && binding?.hostID == host) { block(reason) }
    }
}

// Acceptance is scoped to one restored stream, never to the listening run or a scheduling delay.
extension AmbientListeningReconnect {
    func confirmAcceptance(of audio: AudioPayload, binding: AmbientAudioBinding, on connection: HostConnection) {
        guard audio.isResume, renewed, let pending, self.binding == binding, let streamID = audio.streamID else {
            return
        }
        cancelAcceptance()
        let proof = AmbientResumeAcceptance(streamID: streamID, binding: binding, began: pending.began)
        acceptance = proof
        acceptanceTask = Task { [weak self] in
            do { try await connection.confirmRoundTrip(for: proof) } catch { return }
            self?.accepted(proof)
        }
    }

    /// Keep the owner's destination authorization while replacing this host's transport and confirmation.
    func refreshEndpoint(_ endpoint: HostEndpoint, previous: HostConnectionSnapshot?,
                         store: HostConnectionStore) -> Bool {
        guard let previous, previous.id == endpoint.id else { return false }
        if !isPending { drop(previous, store: store) }
        guard !(previous.endpoint.url.scheme?.lowercased() == "wss" && endpoint.url.scheme?.lowercased() == "ws")
        else { return false }
        guard pending?.binding.hostID == endpoint.id else { return false }
        confirmedPrivacy(on: store.duckMode[endpoint.id]?.isOn() == true, host: endpoint.id)
        controller?.suspendTransport()
        cancelAcceptance()
        privacyConfirmation.cancel()
        renewed = false
        selectionGeneration = nil
        pending?.endpoint = endpoint
        hostName = endpoint.name
        return withinDeadline()
    }

    /// A confirmed private point in this recovery remains a requirement for every replacement transport.
    func confirmedPrivacy(on: Bool, host: HostEndpoint.Identifier) {
        guard on, pending?.binding.hostID == host else { return }
        pending?.privateBeforeDrop = true
    }

    func accepted(_ proof: AmbientResumeAcceptance) {
        guard acceptance === proof else { return }
        acceptance = nil
        acceptanceTask = nil
        if isPending, renewed, withinDeadline() { finish(.applied, reason: nil) }
    }

    private func cancelAcceptance() {
        acceptanceTask?.cancel()
        acceptanceTask = nil
        acceptance = nil
    }
}

/// Retain the ping identity so ordered receive callbacks can observe its pong even before the waiter resumes.
final class AmbientResumeAcceptance: Sendable {
    let nonce = UUID().uuidString.lowercased()
    let streamID: UUID
    let binding: AmbientAudioBinding
    let began: ContinuousClock.Instant
    private let registration = Mutex<UInt64?>(nil)
    var token: UInt64? { registration.withLock { $0 } }

    init(streamID: UUID, binding: AmbientAudioBinding, began: ContinuousClock.Instant) {
        self.streamID = streamID
        self.binding = binding
        self.began = began
    }

    func register(_ token: UInt64?) { registration.withLock { $0 = token } }
}

public extension AmbientListeningReconnect.Reason {
    /// Fixed local log vocabulary; device diagnostics retain the numeric reason for older hosts.
    var diagnosticToken: String? { self == .reauthorizationNeeded ? "reauthorization_needed" : nil }
}
