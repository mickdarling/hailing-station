public import Foundation
import HailProtocol
public import Observation

/// One run's transport recovery (#904). Reassert known privacy; keep owner vetoes latched.
@MainActor
@Observable
public final class AmbientListeningReconnect {
    public enum Reason: Int64, Sendable {
        case ownerStop = 1, ownerSelection, endpointChanged, explicitDisconnect, privacy, modeChanged
        case bindingChanged, targetChanged, startFailed, nonTransport, timedOut, movedAway
    }
    public enum Outcome: Sendable { case applied, blocked, failed }
    public struct Notice: Equatable, Sendable {
        public let id = UUID()
        public let outcome: Outcome
        public let reason: Reason?
        public var notificationTitle: String {
            outcome == .applied ? "Hailing Station reconnected" : "Hailing Station stopped listening"
        }
        public var text: String {
            outcome == .applied ? "Connection dropped and reconnected; listening resumed"
                : "Connection dropped; listening stopped, tap to resume"
        }
    }
    public private(set) var binding: AmbientAudioBinding?
    public private(set) var hostName: String?
    public private(set) var notice: Notice?
    @ObservationIgnored public var onNotice: (@MainActor (Notice) -> Void)?
    @ObservationIgnored weak var controller: AmbientListeningController?
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    @ObservationIgnored let privacyConfirmation = AmbientRestorePrivacy()
    private var pending: Pending?
    private var veto: Reason?
    private var renewed = false
    private var selectionGeneration: UUID?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private struct Pending {
        let endpoint: HostEndpoint
        let binding: AmbientAudioBinding
        let target: TargetInfo?
        let began: ContinuousClock.Instant
        let privateBeforeDrop: Bool
    }
    public init() {}
    public var isPending: Bool { pending != nil }
    public var wantsListening: Bool { isPending }
    var isReauthorizing: Bool { isPending && !renewed && selectionGeneration != nil }
    func ownerStarted() { veto = nil; notice = nil }
    func ownerPrivacyConfirmed() {
        // A settled switch on a healthy stream is pre-drop state. Gap taps and failed sends stay latched.
        if !isPending, controller?.isListening == true, veto == .privacy { veto = nil }
    }
    func block(_ reason: Reason) {
        veto = veto ?? reason // Includes a privacy tap before the receive loop publishes the close, even if send fails.
        guard isPending else { return }
        finish(.blocked, reason: veto)
        controller?.cancelTransportRestore()
    }
    func drop(_ snapshot: HostConnectionSnapshot, store: HostConnectionStore) {
        guard pending == nil, let controller, controller.isListening, let current = controller.binding,
              current.hostID == snapshot.id else { return }
        binding = current
        hostName = snapshot.endpoint.name
        notice = nil
        renewed = false
        selectionGeneration = nil
        pending = Pending(endpoint: snapshot.endpoint, binding: current,
                          target: snapshot.targets.first { $0.id == current.targetID }, began: now(),
                          privateBeforeDrop: store.duckMode[snapshot.id]?.isOn() == true)
        controller.suspendTransport()
        if let veto { return block(veto) }
        if store.privacyLocal[snapshot.id]?.request != nil {
            return block(.privacy)
        }
        deadline = Task { [weak self, sleep] in
            guard (try? await sleep(.seconds(60))) != nil, !Task.isCancelled else { return }
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
            guard let self, let store, self.pending?.binding == intent.binding,
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
                guard let self, let store, self.pending?.binding == intent.binding, !self.renewed else { return }
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
    func sent(_ audio: AudioPayload) {
        if renewed, audio.isResume, withinDeadline() { finish(.applied, reason: nil) }
    }
    func withinDeadline() -> Bool {
        if let pending, now() - pending.began >= .seconds(60) { block(.timedOut); return false }
        return true
    }
    func sendFailed(_ error: any Error, audio: AudioPayload, binding: AmbientAudioBinding,
                    store: HostConnectionStore) {
        guard !(error is CancellationError), !(error is EncodingError),
              !(error is HostConnectionFailure) || (error as? HostConnectionFailure) == .notReady,
              controller?.ownsAudio(audio.streamID, binding: binding) == true,
              let snapshot = store.snapshots[binding.hostID] else { return }
        drop(snapshot, store: store)
    }
    func veto(_ reason: Reason, host: HostEndpoint.Identifier) {
        if controller?.binding?.hostID == host || binding?.hostID == host { block(reason) }
    }
}
