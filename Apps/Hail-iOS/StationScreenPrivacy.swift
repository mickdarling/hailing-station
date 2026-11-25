import Foundation
import HailCore
import HailProtocol

/// The rail and dock use the same displayed switch, including the stopped-listening exception.
struct StationScreenPrivacy: Equatable {
    let privacy: RailPrivacy?
    let intent: PrivacySettingsIntent?

    var title: String {
        if case .status(let status) = privacy, status.isPrivate { return "Leave private mode" }
        return "Go private"
    }

    var dockEnabled: Bool { intent != nil || privacy == .unsupported }

    init(displayedHost: HostEndpoint.Identifier?, binding: AmbientAudioBinding?, liveBinding: AmbientAudioBinding?,
         settings: PrivacySettingsState) {
        guard let host = settings.host, host.id == displayedHost, host.state == .ready,
              liveBinding == nil || (liveBinding == binding && liveBinding?.hostID == host.id
                                     && liveBinding?.connectionGeneration == host.connectionGeneration),
              !settings.isListeningToHost || liveBinding != nil else {
            (privacy, intent) = (nil, nil)
            return
        }
        guard host.capabilities.contains(DuckMode.privacySwitchCapability) else {
            (privacy, intent) = (.unsupported, nil)
            return
        }
        privacy = .status(settings.privacy)
        intent = settings.canRequestPrivacy && !settings.privacy.pending
            ? .privacy(!settings.privacy.isPrivate, host: host.id, generation: host.connectionGeneration) : nil
    }
}
