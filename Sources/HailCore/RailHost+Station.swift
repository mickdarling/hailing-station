public import Foundation

extension RailHost {
    /// Connection and handoff observations accompany the privacy observation used by the controls.
    @MainActor public init(
        store: HostConnectionStore, privacy: RailPrivacy?, availability: StationAvailability
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
        self.init(privacy: privacy, handoff: controller?.handoff, availability: availability, connection: connection)
    }
}
