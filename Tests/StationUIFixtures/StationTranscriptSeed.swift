#if STATION_UI_FIXTURES
import Foundation
import HailCore

/// A display-seed request is confined to the isolated Mac UI-test app or an iOS simulator.
enum StationDisplaySeedLaunch {
    static func name(in arguments: [String], bundleID: String?, shellEnabled: Bool) -> String? {
        #if os(macOS) || targetEnvironment(simulator)
        #if os(macOS)
        guard bundleID == "com.mickdarling.Hail-macOS-shell-tests" else { return nil }
        #endif
        guard shellEnabled, arguments.contains("-reset-station-state"), arguments.contains("-seed-navigation-shell"),
              let flag = arguments.firstIndex(of: "-seed-station-state") else { return nil }
        // Even a malformed fixture request stays in the display-only window.
        return arguments.dropFirst(flag + 1).first ?? ""
        #else
        return nil
        #endif
    }
}

/// Immutable inputs for rendering the real Station components. No store, controllers, transport or input actions.
enum StationTranscriptSeed: String, CaseIterable, Sendable {
    case listening, `private`, pending, recording, handoff, media, ready, held, refused

    static let session = DestinationLabel(hostName: "Studio Mac", targetName: "Workbench",
                                          targetKind: "tmux", targetID: "fixture-workbench")

    var listeningPhase: StationMenuStatus.Listening {
        switch self {
        case .ready, .recording: .off
        case .handoff: .elsewhere
        case .listening, .private, .pending, .media, .held, .refused: .listening
        }
    }

    var privacy: PrivacySwitchStatus {
        let instant = Date(timeIntervalSince1970: 0)
        return PrivacySwitchStatus(ready: true, duck: DuckModeStatus(on: self == .private),
                                   requested: self == .pending ? PrivacyRequest(on: true, at: instant) : nil,
                                   now: instant)
    }

    func rail(on device: StationNavigationIdiom) -> ListeningPrivacyRailState {
        let handoff: AmbientHandoff? = self == .handoff ? .movedAway(to: device == .phone ? "pad" : "phone") : nil
        let host = RailHost(privacy: .status(privacy), handoff: handoff, availability: .ready, connection: nil)
        return .resolve(mic: listeningPhase.isOn || self == .recording ? .live : .off,
                        listening: listeningPhase, talk: talkPhase, host: host)
    }

    private var talkPhase: TalkCapturePhase { self == .recording ? .recording : .idle }

    var dock: VoiceDockState {
        let accessories = DockAccessories(escape: true, privacy: true, paste: true)
        return .resolve(talk: TalkActivity(phase: talkPhase, sendPending: false, interrupting: false),
                        destination: .confirmed(Self.session), accessories: accessories)
    }
}
#endif
