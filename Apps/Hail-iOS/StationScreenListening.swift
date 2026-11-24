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
                             liveBinding: connections.ambientController?.binding, settings: privacySettingsState(now: date))
    }

    func activateStationPrivacy(_ shown: StationScreenPrivacy) {
        guard case .privacy(let on, let host, let generation) = shown.intent else { return }
        Task { @MainActor in
            guard stationPrivacy() == shown else { return }
            await requestPrivacy(on, host: host, generation: generation)
        }
    }

    func stationRail(talk: TalkCapturePhase?, details: Binding<Bool>) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let privacy = stationPrivacy(at: context.date)
            let host = RailHost(store: connections, privacy: privacy.privacy, availability: stationAvailability)
            // The classic owners do not publish process-wide input-engine state.
            let mic = MicLiveInputs(engine: .unknown, ambient: listeningPhase, talk: talk)
            let state = ListeningPrivacyRailState.resolve(mic: mic.state, listening: listeningPhase,
                                                           talk: talk, host: host)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ListeningPrivacyRailView(state: state, isDetailPresented: details,
                                             listeningDevice: listeningPhase == .listening && talk == .idle
                                                ? localDeviceTitle : nil)
                    Button(privacy.title) { activateStationPrivacy(privacy) }
                        .disabled(privacy.intent == nil)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("station.rail.privacy")
                }
                if details.wrappedValue {
                    Text(state.detail).font(.callout).accessibilityIdentifier("station.rail.detail")
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
        .resolve(availability: stationAvailability, destination: screenDestination, privacy: stationPrivacy(at: date).privacy,
                        listening: (listeningPhase, hasListeningRecovery || listeningPhase.isOn), turn: turn)
    }
}
