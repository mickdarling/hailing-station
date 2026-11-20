import HailCore
import SwiftUI

@MainActor
protocol PrivacySettingsOwner {
    var connections: HostConnectionStore { get }
    var selectedHostID: HostEndpoint.Identifier? { get }
    var settingsShowOverheard: Bool { get nonmutating set }
    var settingsWhoseOverheard: String { get nonmutating set }
    var privacySettingsRequest: PrivacySettingsRequestState { get nonmutating set }
}

extension StationRootView: PrivacySettingsOwner {}

extension StationRootView {
    /// The same scene-owned model is observed here and passed to the existing tool. Merely visiting the overview
    /// does not subscribe, refresh, activate, select a route or perform cleanup.
    var audioSettingsOverview: some View {
        AudioSettingsOverview(model: audioRoutes)
    }

    #if !SWIFT_PACKAGE
    var voicesSettingsOverview: some View {
        VoicesSettingsOverview(playback: playback) {
            NavigationLink {
                ReplySegmentToolsView(playback: playback, gate: echoGuard.segmentOnsetGate)
            } label: {
                Label("Turn-taking", systemImage: "pause.circle")
            }
            .accessibilityIdentifier("settings.voices.turn-taking")
        }
    }

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

extension PrivacySettingsOwner {
    var privacySettingsOverview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PrivacySettingsView(state: privacySettingsState(now: context.date), send: performPrivacySettings)
        }
    }

    func privacySettingsState(now: Date = Date()) -> PrivacySettingsState {
        let host = selectedHostID.flatMap { connections.snapshots[$0] }
        let listening = connections.ambientController?.binding?.hostID == host?.id
            && connections.ambientController?.isListening == true
        let privacy = host.map { connections.privacySwitch($0.id, listening: listening, now: now) }
            ?? PrivacySwitchStatus(ready: false, duck: nil, requested: nil, now: now)
        return PrivacySettingsState(
            host: host, privacy: privacy, isListeningToHost: listening,
            unavailableReason: privacyUnavailableReason(host: host, listening: listening, now: now),
            canStopListening: connections.ambientController?.isOn == true,
            showOverheard: settingsShowOverheard, whoseOverheard: settingsWhoseOverheard,
            requestedScope: connections.overheardScope, failure: privacySettingsRequest.failure)
    }

    func performPrivacySettings(_ intent: PrivacySettingsIntent) {
        switch intent {
        case .privacy(let on, let host, let generation):
            let request = PrivacySettingsRequestState()
            privacySettingsRequest = request
            Task { await requestPrivacy(on, host: host, generation: generation, request: request.id) }
        case .showOverheard(let show):
            guard !show || ["owner", "everyone"].contains(settingsWhoseOverheard) else {
                privacySettingsRequest.failure = "Choose whose remarks to show first."
                return
            }
            settingsShowOverheard = show
            connections.setOverheardScope(show ? settingsWhoseOverheard : "off")
        case .whoseOverheard(let whose):
            guard ["owner", "everyone"].contains(whose) else {
                privacySettingsRequest.failure = "That overheard scope is not supported."
                return
            }
            settingsWhoseOverheard = whose
            connections.setOverheardScope(settingsShowOverheard ? whose : "off")
        case .stopListening:
            if let controller = connections.ambientController, controller.isOn {
                Task { await controller.turnOff() }
            }
        }
    }

    private func requestPrivacy(_ on: Bool, host: HostEndpoint.Identifier, generation: UUID, request: UUID) async {
        let current = privacySettingsState()
        let name = connections.snapshots[host]?.endpoint.name ?? "the previously selected Mac"
        guard current.host?.id == host, current.host?.connectionGeneration == generation,
              current.canRequestPrivacy else {
            if privacySettingsRequest.id == request {
                privacySettingsRequest.failure = "Privacy request for \(name) was not sent. Review its current state."
            }
            return
        }
        do {
            try await connections.setPrivacy(on: on, host: host)
        } catch {
            if privacySettingsRequest.id == request {
                privacySettingsRequest.failure = "Privacy request for \(name) failed: \(error.localizedDescription)"
            }
        }
    }

    private func privacyUnavailableReason(host: HostConnectionSnapshot?, listening: Bool, now: Date) -> String? {
        guard let host else { return "Choose a Mac in Station to see its privacy state." }
        guard host.state == .ready else { return "The Mac is not connected. Privacy is not confirmed." }
        guard connections.canSetPrivacy(host.id) else { return "This Mac does not support the privacy switch." }
        if connections.privacySwitch(host.id, listening: listening, now: now).pending {
            return "Waiting for the Mac to confirm."
        }
        guard connections.showsPrivacySwitch(host.id, listening: listening, now: now) else {
            return "Available while this device is listening to this Mac."
        }
        return nil
    }
}
