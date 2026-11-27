#if os(macOS)
import HailCore
import SwiftUI

/// Only peripheral destinations are inert. The root's launch branch, shell, collapse and card remain real.
struct ConnectivityLabView: View {
    let store: HostConnectionStore
    let endpointsChanged: @MainActor ([HostEndpoint]) -> Void
    var showsDevicesPage = false
    var body: some View { Text("Mac Setup fixture") }
}

struct CaptureSafeLabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let playback: ReplyPlaybackController
    var body: some View { Text("Labs fixture") }
}

struct ReplySegmentToolsView: View {
    let playback: ReplyPlaybackController
    let gate: ReplySegmentOnsetGate
    var body: some View { Text("Turn-taking fixture") }
}

extension StationRootView {
    // These three app projections are excluded by SWIFT_PACKAGE. This lifetime fixture does not open them;
    // their actual renderers and owner adapters have independent Settings tests and gallery scenes.
    var voicesSettingsOverview: some View { Text("Voices and replies destination fixture") }
    var targetsSettingsOverview: some View { Text("Targets destination fixture") }
    var advancedSettingsOverview: some View { Text("Advanced and diagnostics destination fixture") }
}

extension View {
    // Exactly the platform-cosmetic Mac branch; no iOS toolbar or lifetime behavior is simulated here.
    func stationHiddenNavigationBar() -> some View { self }
}
#endif
