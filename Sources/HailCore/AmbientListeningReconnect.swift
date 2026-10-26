public import Foundation
import HailProtocol
public import Observation

/// One app run's transport recovery intent (#904). No endpoint or target is persisted or logged.
@MainActor
@Observable
public final class AmbientListeningReconnect {
    /// Stable numeric diagnostic reasons; sent with the existing closed protocol vocabulary.
    public enum Reason: Int64, Sendable {
        case ownerStop = 1, ownerSelection, endpointChanged, explicitDisconnect, privacy, modeChanged
        case bindingChanged, targetChanged, background, startFailed, nonTransport
    }
    public enum Outcome: String, Sendable { case applied, blocked, failed }
    public struct Notice: Equatable, Sendable {
        public let id = UUID()
        public let outcome: Outcome
        public let reason: Reason?
        public var text: String {
            outcome == .applied ? "Connection dropped and reconnected; listening resumed"
                : "Connection dropped and reconnected; listening stopped, tap to resume"
        }
    }

    /// Also keeps the card present while the ready-only destination is unavailable.
    public private(set) var binding: AmbientAudioBinding?
    public private(set) var hostName: String?
    public private(set) var notice: Notice?
    @ObservationIgnored public var onNotice: (@MainActor (Notice) -> Void)?
    private var pending: Pending?
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var attempting = false
    @ObservationIgnored private var startAllowed: (@MainActor () -> Bool)?

    private struct Pending {
        let id = UUID()
        let endpoint: HostEndpoint
        let binding: AmbientAudioBinding
        let target: TargetInfo?
        var reason: Reason?
    }

    public var isPending: Bool { pending != nil }
    var permitsStart: Bool { !attempting || (pending?.reason == nil && startAllowed?() == true) }

    public init() {}

    public var wantsListening: Bool { pending != nil && pending?.reason == nil }

    func ownerStarted() { notice = nil; block(.ownerStop) }

    func block(_ reason: Reason) {
        guard pending != nil else { return }
        if pending?.reason == nil { pending?.reason = reason }
    }

    func drop(_ snapshot: HostConnectionSnapshot, controller: AmbientListeningController?, store: HostConnectionStore) {
        guard pending == nil, let controller, controller.isOn, let current = controller.binding,
              current.hostID == snapshot.id else { return }
        binding = current
        hostName = snapshot.endpoint.name
        notice = nil
        pending = Pending(endpoint: snapshot.endpoint, binding: current,
                          target: snapshot.targets.first { $0.id == current.targetID })
        if store.duckMode[snapshot.id]?.isOn() == true || store.privacyLocal[snapshot.id]?.request != nil {
            block(.privacy)
        }
        if store.mediaMode[snapshot.id]?.on == true { block(.modeChanged) }
        // Mark intent before a view update or a failed audio send can end the old controller.
        teardown = Task { await controller.destinationLost() }
    }

    func receive(_ snapshot: HostConnectionSnapshot, previous: HostConnectionSnapshot?,
                 controller: AmbientListeningController?, store: HostConnectionStore) {
        recordDrop(snapshot, previous: previous, controller: controller, store: store)
        guard pending?.binding.hostID == snapshot.id else { return }
        if case .failed = snapshot.state { block(.nonTransport) }
        if snapshot.state == .disconnected { block(.explicitDisconnect) }
        if snapshot.endpoint != pending?.endpoint { block(.endpointChanged) }
        guard snapshot.state == .ready, snapshot.receivedTargetList else { return }
        if !snapshot.capabilities.contains(HostConnection.streamAudioCapability) { block(.bindingChanged) }
        if !snapshot.targets.contains(where: { $0 == pending?.target && $0.alive }) { block(.targetChanged) }
        Task { await self.restore(controller: controller, store: store) }
    }

    private func recordDrop(_ snapshot: HostConnectionSnapshot, previous: HostConnectionSnapshot?,
                            controller: AmbientListeningController?, store: HostConnectionStore) {
        if previous?.state == .ready, snapshot.state != .ready, let previous {
            switch snapshot.state {
            case .reconnecting, .connecting: drop(previous, controller: controller, store: store)
            default: break // explicit disconnects and protocol/host failures never arm recovery
            }
        }
    }

    /// Consumes an intent once, after ordinary selection confirmation, then uses the ordinary start path.
    func restore(controller: AmbientListeningController?, store: HostConnectionStore,
                 confirmedHost: HostEndpoint.Identifier? = nil) async {
        guard let intent = pending, let controller, !attempting else { return }
        let snapshot = store.snapshots[intent.binding.hostID]
        let reconnected = snapshot?.state == .ready && snapshot?.receivedTargetList == true
            && snapshot?.connectionGeneration != intent.binding.connectionGeneration
        guard reconnected || (intent.reason != nil && confirmedHost != nil) else { return }
        let current = store.ambientBinding(host: intent.binding.hostID, targetID: intent.binding.targetID)
        guard intent.reason != nil || !controller.reconnectForeground || current != nil else { return }
        attempting = true
        defer { attempting = false; startAllowed = nil }
        await teardown?.value
        guard pending?.id == intent.id else { return }
        if let reason = pending?.reason { return finish(.blocked, reason: reason, controller: controller) }
        if !controller.reconnectForeground { return finish(.blocked, reason: .background, controller: controller) }
        guard let current, current.hostID == intent.binding.hostID,
              current.targetID == intent.binding.targetID, current.selection == intent.binding.selection,
              store.snapshots[current.hostID]?.endpoint == intent.endpoint else {
            return finish(.blocked, reason: .bindingChanged, controller: controller)
        }
        startAllowed = { [weak store] in
            store?.ambientBinding(host: current.hostID, targetID: current.targetID) == current
                && store?.duckMode[current.hostID]?.isOn() != true
                && store?.mediaMode[current.hostID]?.on != true
                && store?.privacyLocal[current.hostID]?.request == nil
        }
        guard startAllowed?() == true else { return finish(.blocked, reason: .privacy, controller: controller) }
        binding = current
        await controller.beginListening(for: current)
        if controller.isListening, permitsStart {
            binding = current
            finish(.applied, reason: nil, controller: controller)
        } else {
            let reason = pending?.reason ?? (controller.reconnectForeground ? .startFailed : .background)
            await controller.destinationLost() // also cancels a permission alert's deferred foreground start
            finish(pending?.reason == nil ? .failed : .blocked, reason: reason, controller: controller)
        }
    }

    private func finish(_ outcome: Outcome, reason: Reason?, controller: AmbientListeningController) {
        pending = nil
        teardown = nil
        notice = Notice(outcome: outcome, reason: reason)
        // Older hosts reject new diagnostic tokens. The event and every field remain in their vocabulary.
        controller.diagnostics?.record(.captureState, [
            .state: .token("reconnecting"), .on: .boolean(outcome == .applied),
            .error: .integer(reason?.rawValue ?? 0), .code: .token(outcome == .failed ? "resume_failed" : "other")
        ])
        if let notice { onNotice?(notice) }
    }
}

// A send may see a closed socket before its receive loop publishes reconnecting. Remember that live stream's
// intent now, but restore only after a different generation reaches ready. Stale streams cannot arm recovery.
extension AmbientListeningReconnect {
    func sendFailed(_ error: any Error, audio: AudioPayload, binding: AmbientAudioBinding,
                    controller: AmbientListeningController?, store: HostConnectionStore) {
        guard !(error is CancellationError), !(error is EncodingError),
              !(error is HostConnectionFailure) || (error as? HostConnectionFailure) == .notReady,
              controller?.ownsAudio(audio.streamID, binding: binding) == true,
              store.ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding,
              let snapshot = store.snapshots[binding.hostID] else { return }
        drop(snapshot, controller: controller, store: store)
    }
}
