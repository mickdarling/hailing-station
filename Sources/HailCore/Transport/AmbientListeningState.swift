import Foundation
import Observation

/// The owner action authorizes a destination across replaceable socket and microphone attempts.
enum AmbientListeningState: Equatable, Sendable {
    struct Destination: Equatable, Sendable {
        let hostID: HostEndpoint.Identifier
        let endpointURL: String?
        let targetID: String
        let selection: UInt64

        init(_ binding: AmbientAudioBinding) {
            hostID = binding.hostID
            endpointURL = binding.endpointURL
            targetID = binding.targetID
            selection = binding.selection
        }
    }

    struct Intent: Equatable, Sendable {
        let generation: UUID
        let destination: Destination
    }

    enum LegacyStopPath: CaseIterable, Equatable, Sendable {
        case systemCaptureEnded, socketBindingLost, privacySendFailed, privacyUnconfirmed
        case leftForeground, captureStartFailed, sendCancelled, encodingFailed, sendFailed
        case hostRefused, retriesExhausted, replacementFailed, diagnosticsDismissed
    }

    enum StopReason: Equatable, Sendable {
        case ownerOff, ownerReselect, ownerRemove, ownerDisconnect, privacyStop, sceneDisposed
        case policyDenied, microphonePermissionDenied, targetRemoved, capabilityRemoved, unsafeEndpointChange, movedAway
        case legacy(LegacyStopPath)
    }

    enum Event: Equatable, Sendable {
        case ownerStart(Destination), stop(StopReason)
        case transportLost, transportReady, selectionConfirmed, privacyConfirmed
        case interruptionBegan, interruptionEnded, routeChanged, routeSettled, captureInvalidated
        case sceneChanged, micRetryDue, captureRebuildAuthorized
        case preferenceChanged(masksDuringReplies: Bool)
    }

    case off
    case on(Intent)
    case stopped(StopReason)

    var intent: Intent? {
        guard case .on(let intent) = self else { return nil }
        return intent
    }

    func transition(_ event: Event, generation: UUID) -> Self {
        switch event {
        case .ownerStart(let destination) where intent == nil:
            return .on(Intent(generation: generation, destination: destination))
        case .stop(let reason) where intent?.generation == generation:
            return .stopped(reason)
        default:
            return self
        }
    }
}

/// A controller can submit transitions and observe the result. Only this owner publishes intent.
@MainActor
@Observable
final class AmbientListeningOwner {
    private(set) var state = AmbientListeningState.off

    func apply(_ event: AmbientListeningState.Event, generation: UUID) {
        let next = state.transition(event, generation: generation)
        if next != state { state = next }
    }
}

extension AmbientListeningState.StopReason {
    /// Attribute an existing stop from the host's authoritative advertisement.
    static func bindingLoss(_ binding: AmbientAudioBinding?, snapshot: HostConnectionSnapshot?) -> Self {
        if let binding, let snapshot, snapshot.state == .ready {
            if !snapshot.capabilities.contains(HostConnection.streamAudioCapability) { return .capabilityRemoved }
            if snapshot.receivedTargetList {
                return targetLoss(binding.targetID, in: snapshot)
            }
        }
        return .legacy(.socketBindingLost)
    }

    static func targetLoss(_ id: String, in snapshot: HostConnectionSnapshot) -> Self {
        snapshot.targets.contains { $0.id == id && $0.alive } ? .legacy(.socketBindingLost) : .targetRemoved
    }

    static func sendError(_ error: any Error, destinationReason: @autoclosure () -> Self) -> Self {
        switch error {
        case is CancellationError: return .legacy(.sendCancelled)
        case let cancellation as URLError where cancellation.code == .cancelled:
            return .legacy(.sendCancelled)
        case is EncodingError, is AmbientAudioError: return .legacy(.encodingFailed)
        case HostConnectionFailure.unsupportedCapability(HostConnection.streamAudioCapability):
            return .capabilityRemoved
        case HostConnectionFailure.remote(let message) where message.hasPrefix("unauthorized:"): return .policyDenied
        case HostConnectionFailure.remote: return .legacy(.hostRefused)
        case HostConnectionFailure.notReady: return destinationReason()
        case is URLError, is POSIXError: return .legacy(.socketBindingLost)
        default: return .legacy(.sendFailed)
        }
    }
}
