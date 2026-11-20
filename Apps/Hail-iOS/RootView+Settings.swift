import HailCore
import SwiftUI

extension StationRootView {
    /// The same scene-owned model is observed here and passed to the existing tool. Merely visiting the overview
    /// does not subscribe, refresh, activate, select a route or perform cleanup.
    var audioSettingsOverview: some View {
        AudioSettingsOverview(model: audioRoutes)
    }

    #if !SWIFT_PACKAGE
    var advancedSettingsOverview: some View {
        AdvancedSettingsOverview(
            diagnostics: diagnostics, collectingHostName: connections.diagnosticsCollectingHost?.endpoint.name,
            buildInfo: StationBuildInfo()
        ) {
            NavigationLink {
                CaptureSafeLabsView(audioSession: audioRoutes, playback: playback)
            } label: {
                Label("Labs", systemImage: "wrench.and.screwdriver")
            }
            .accessibilityIdentifier("settings.advanced.labs")
            NavigationLink {
                ReplySegmentToolsView(playback: playback, gate: echoGuard.segmentOnsetGate)
            } label: {
                Label("Turn-taking", systemImage: "pause.circle")
            }
            .accessibilityIdentifier("settings.advanced.turn-taking")
        }
    }
    #endif
}

/// The reference is supplied by the root; this renderer creates no audio or persistence owner.
struct AudioSettingsOverview: View {
    let model: AudioRouteModel

    var body: some View {
        AudioSettingsOverviewView(
            state: AudioRoutesSheetState.resolve(
                diagnostics: model.diagnostics, inputs: model.inputs,
                preferred: model.preferredInput, selection: model.selectionState, hfp: nil),
            preferredInput: model.preferredInput, sessionStatus: model.status
        ) {
            AudioDiagnosticsView(model: model)
        }
    }
}

/// Observes the root's existing log. Only the explicit toggle intent calls its existing setter.
struct AdvancedSettingsOverview<Tools: View>: View {
    let diagnostics: DeviceDiagnostics
    let collectingHostName: String?
    let buildInfo: StationBuildInfo
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        AdvancedSettingsView(
            diagnosticsEnabled: diagnostics.isEnabled, bufferedEvents: diagnostics.bufferedCount,
            collectingHostName: collectingHostName, buildInfo: buildInfo, send: apply, tools: tools
        )
    }

    func apply(_ intent: AdvancedSettingsIntent) {
        switch intent {
        case .setDiagnosticsEnabled(let enabled): diagnostics.setEnabled(enabled)
        }
    }
}
