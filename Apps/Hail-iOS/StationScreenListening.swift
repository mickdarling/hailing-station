import HailCore
import SwiftUI

extension RootView {
    private var listeningPhase: StationMenuStatus.Listening {
        connections.ambientController.map(StationMenuListeningPublisher.phase) ?? .off
    }

    // A newly selected host cannot describe or change another stream still draining.
    private var listeningAtDestination: Bool {
        guard let active = connections.ambientController?.binding else { return false }
        return active == ambientDestinationBinding && listeningPhase == .listening
    }

    func stationPrivacy(at date: Date = .now) -> StationScreenPrivacy {
        StationScreenPrivacy(displayedHost: destination?.hostID, binding: ambientDestinationBinding,
                             liveBinding: connections.ambientController?.binding,
                             settings: privacySettingsState(now: date))
    }

    func activateStationPrivacy(_ shown: StationScreenPrivacy) {
        guard let intent = shown.intent, case .privacy(_, let host, let generation) = intent else { return }
        performPrivacySettings(intent) {
            destination?.hostID == host && connections.snapshots[host]?.connectionGeneration == generation
                && stationPrivacy() == shown
        }
    }

    func stationRail(talk: TalkCapturePhase?, details: Binding<Bool>, privacy: StationScreenPrivacy) -> some View {
        let host = RailHost(store: connections, privacy: privacy.privacy, availability: stationAvailability)
        let rail = StationListeningRail(listening: listeningPhase, talk: talk, host: host)
        return VStack(alignment: .leading, spacing: 4) {
            StationCaptureRail(rail: rail, ambientEngine: echoGuard.ambientInputEngineState,
                               listeningDevice: rail.capture == .ambient ? localDeviceTitle : nil,
                               details: details, privacy: privacy) {
                activateStationPrivacy(privacy)
            }
            if case .status(let privacy) = host.privacy, privacy.pending {
                Label("Privacy is not confirmed yet. Waiting for the Mac.", systemImage: "clock")
                    .font(.callout)
                    .accessibilityIdentifier("station.rail.privacy-pending")
            }
            if let failure = privacySettingsRequest.failure { Text(failure).font(.callout) }
            if listeningAtDestination, let id = destination?.hostID, let media = connections.mediaMode[id] {
                MediaModeStatusView(status: media)
            }
        }
        .padding(.horizontal, 12)
    }

    private var localDeviceTitle: String {
        switch StationRedesignLaunch.idiom {
        case .mac: "Mac"
        case .pad: "iPad"
        case .phone: "iPhone"
        }
    }

    var hasListeningRecovery: Bool {
        let reconnect = connections.ambientController?.reconnect
        return reconnect?.isPending == true || reconnect?.notice.map { $0.outcome != .applied } == true
    }

    func recoveryState(at date: Date, turn: TurnOutcome?) -> RecoverySheetState {
        .resolve(availability: stationAvailability, destination: screenDestination,
                 privacy: stationPrivacy(at: date).privacy,
                 listening: (listeningPhase, hasListeningRecovery || listeningPhase.isOn), turn: turn)
    }
}

/// Read only the installed window's Talk resources, and only while its dock reports a recording.
private struct StationCaptureRail: View {
    let rail: StationListeningRail
    let ambientEngine: MicEngineState
    let listeningDevice: String?
    @Binding var details: Bool
    let privacy: StationScreenPrivacy
    let activatePrivacy: () -> Void
    @StationTranscriptionView.WindowTalk var talkSession

    private var engine: MicEngineState {
        switch rail.capture {
        case .inactive: return .unknown
        case .ambient: return ambientEngine
        case .talk:
            guard let owner = talkSession.owner, CapturePlaybackSuppression.liveness[owner]?() == true,
                  let input = talkSession.resources.capture as? AVAudioEngineCapture else { return .unknown }
            return input.inputEngineState
        }
    }

    var body: some View {
        let (state, style) = rail.presentation(engine: engine)
        HStack {
            ListeningPrivacyRailView(state: state, isDetailPresented: $details, listeningDevice: listeningDevice,
                                     barStyle: style)
            Button(privacy.title, action: activatePrivacy)
                .disabled(privacy.intent == nil)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("station.rail.privacy")
        }
        if details {
            Text(state.detail).font(.callout).accessibilityIdentifier("station.rail.detail")
        }
    }
}
