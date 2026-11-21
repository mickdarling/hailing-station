import HailCore
import SwiftUI

extension StationRootView {
    var listeningSettingsOverview: some View {
        ListeningSettingsOverview(connections: connections, masksDuringReplies: $settingsMasksDuringReplies) {
            navigation.apply(.select(.station))
        }
    }
}

/// The existing station card remains the sole application path for the saved echo-mask preference.
struct ListeningSettingsOverview: View {
    let connections: HostConnectionStore
    @Binding var masksDuringReplies: Bool
    let openStation: () -> Void

    var body: some View {
        ListeningSettingsView(
            state: ListeningSettingsState(controller: connections.ambientController),
            masksDuringReplies: masksDuringReplies, send: apply
        )
    }

    func apply(_ intent: ListeningSettingsIntent) {
        switch intent {
        case .setMaskPreference(let masks): masksDuringReplies = masks
        case .manageInStation: openStation()
        }
    }
}
