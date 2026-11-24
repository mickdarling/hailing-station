public import Foundation

extension RailHost {
    /// A confirmed selection and its current binding come from the root. During a re-selection, an old
    /// microphone can still be live. Only its own binding may supply the privacy claim for that stream.
    @MainActor public init(
        store: HostConnectionStore, confirmedHost: HostEndpoint.Identifier?, binding: AmbientAudioBinding?,
        availability: StationAvailability, now: Date
    ) {
        let controller = store.ambientController
        let reconnect = controller?.reconnect
        var connection: RailConnection?
        if reconnect?.isPending == true {
            connection = .reconnecting
        } else if let notice = reconnect?.notice, notice.outcome != .applied {
            connection = .stopped(reason: notice.text)
        } else if let reason = controller?.stopReason {
            connection = .stopped(reason: reason)
        }
        let privacy = confirmedHost.flatMap { host -> RailPrivacy? in
            guard store.snapshots[host]?.state == .ready else { return nil }
            let listening = controller?.isListening == true
            if listening {
                guard let binding, binding.hostID == host, binding == controller?.binding else { return nil }
            }
            guard store.canSetPrivacy(host) else { return .unsupported }
            return .status(store.privacySwitch(host, listening: listening, now: now))
        }
        self.init(privacy: privacy, handoff: controller?.handoff, availability: availability, connection: connection)
    }
}
