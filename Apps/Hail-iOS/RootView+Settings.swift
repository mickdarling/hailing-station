import HailCore
import SwiftUI

extension StationRootView {
    /// The same scene-owned model is observed here and passed to the existing tool. Merely visiting the overview
    /// does not subscribe, refresh, activate, select a route or perform cleanup.
    var audioSettingsOverview: some View {
        AudioSettingsOverview(model: audioRoutes)
    }
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
