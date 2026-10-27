public import Foundation

/// A snapshot of the core state used by the root destination and ambient card.
/// Notices describe history; only pending recovery can retain an unavailable destination's card.
public struct AmbientRestorePresentation: Sendable {
    public let confirmedBinding: AmbientAudioBinding?
    public let notice: AmbientListeningReconnect.Notice?
    private let controllerBinding: AmbientAudioBinding?
    private let recoveryBinding: AmbientAudioBinding?
    private let recoveryHostName: String?
    private let isListening: Bool
    private let isOn: Bool
    private let isPending: Bool

    @MainActor
    public init(controller: AmbientListeningController?, confirmedBinding: AmbientAudioBinding?) {
        self.confirmedBinding = confirmedBinding
        notice = controller?.reconnect.notice
        controllerBinding = controller?.binding
        recoveryBinding = controller?.reconnect.binding
        recoveryHostName = controller?.reconnect.hostName
        isListening = controller?.isListening == true
        isOn = controller?.isOn == true
        isPending = controller?.reconnect.isPending == true
    }

    /// Only core's applied, still-current binding may advance authorization without a foreground selection.
    public func appliedBinding(hostID: HostEndpoint.Identifier?, targetID: String?) -> AmbientAudioBinding? {
        guard isListening, notice?.outcome == .applied, !isPending,
              let binding = recoveryBinding, controllerBinding == binding,
              hostID == binding.hostID, targetID == binding.targetID,
              confirmedBinding == binding else { return nil }
        return binding
    }

    /// The root may use a successful background restore before its foreground selection task runs.
    public func authorizedGeneration(hostID: HostEndpoint.Identifier?, targetID: String?,
                                     foregroundAuthorized: Bool, generation: UUID?) -> UUID? {
        let restored = appliedBinding(hostID: hostID, targetID: targetID)
        guard foregroundAuthorized || restored != nil else { return nil }
        return restored?.connectionGeneration ?? generation
    }

    public func card(hostName: String?) -> (AmbientAudioBinding, String)? {
        if let binding = confirmedBinding, let hostName { return (binding, hostName) }
        guard isPending, let binding = recoveryBinding, let name = recoveryHostName else { return nil }
        return (binding, name)
    }

    /// History and a pending card's cached binding never authorize an owner start.
    public var resumeBinding: AmbientAudioBinding? { confirmedBinding }
    public var offersResume: Bool { notice != nil && notice?.outcome != .applied && !isOn }
}
