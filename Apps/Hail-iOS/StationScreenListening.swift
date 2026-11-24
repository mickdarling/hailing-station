import HailCore
import SwiftUI

extension RootView {
    private var listeningPhase: StationMenuStatus.Listening {
        connections.ambientController.map(StationMenuListeningPublisher.phase) ?? .off
    }

    private func railHost(at date: Date) -> RailHost {
        let controller = connections.ambientController
        let reconnect = controller?.reconnect
        var connection: RailConnection?
        if reconnect?.isPending == true {
            connection = .reconnecting
        } else if let notice = reconnect?.notice, notice.outcome != .applied {
            connection = .stopped(reason: notice.text)
        } else if let reason = controller?.stopReason {
            connection = .stopped(reason: reason)
        }
        let privacy: RailPrivacy? = destination.map {
            connections.canSetPrivacy($0.hostID)
                ? .status(connections.privacySwitch($0.hostID, listening: listeningPhase == .listening, now: date))
                : .unsupported
        }
        return RailHost(privacy: privacy, handoff: controller?.handoff, availability: stationAvailability,
                        connection: connection)
    }

    func stationRail(talk: TalkCapturePhase?, details: Binding<Bool>) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let host = railHost(at: context.date)
            let mic = MicLiveInputs(engine: AVAudioEngineCapture.microphoneState, ambient: listeningPhase, talk: talk)
            let state = ListeningPrivacyRailState.resolve(mic: mic.state, listening: listeningPhase,
                                                           talk: talk, host: host)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ListeningPrivacyRailView(state: state, isDetailPresented: details,
                                             listeningDevice: listeningPhase == .listening && talk == .idle
                                                ? localDeviceTitle : nil)
                    if let intent = stationPrivacyIntent(at: context.date) {
                        Button(privacyActionTitle(host.privacy)) { performPrivacySettings(intent) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("station.rail.privacy")
                    }
                }
                if details.wrappedValue { Text(state.detail).font(.callout) }
                if let failure = privacySettingsRequest.failure { Text(failure).font(.callout) }
                if listeningPhase == .listening, let id = destination?.hostID, let media = connections.mediaMode[id] {
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

    private func privacyActionTitle(_ privacy: RailPrivacy?) -> String {
        if case .status(let status) = privacy, status.isPrivate { return "Leave private mode" }
        return "Go private"
    }

    func stationPrivacyIntent(at date: Date = .now) -> PrivacySettingsIntent? {
        let state = privacySettingsState(now: date)
        guard let host = state.host, host.id == destination?.hostID,
              state.canRequestPrivacy, !state.privacy.pending else { return nil }
        return .privacy(!state.privacy.isPrivate, host: host.id, generation: host.connectionGeneration)
    }

    var hasListeningRecovery: Bool {
        let reconnect = connections.ambientController?.reconnect
        return reconnect?.isPending == true || reconnect?.notice != nil
    }

    func recoveryState(at date: Date, turn: TurnOutcome?) -> RecoverySheetState {
        let host = railHost(at: date)
        return .resolve(availability: stationAvailability, destination: screenDestination, privacy: host.privacy,
                        listening: (listeningPhase, hasListeningRecovery || listeningPhase.isOn), turn: turn)
    }
}
