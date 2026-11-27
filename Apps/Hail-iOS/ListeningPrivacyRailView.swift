import HailCore
import SwiftUI

/// The owners that can confirm this station is on air. A phase alone cannot confirm its engine is running.
enum StationListeningCapture: CaseIterable, Sendable {
    case inactive, ambient, talk

    init(listening: StationMenuStatus.Listening?, talk: TalkCapturePhase?) {
        switch talk {
        case .recording?: self = .talk
        case .idle?:
            switch listening {
            case .listening?: self = .ambient
            case .off?, .starting?, .paused?, .elsewhere?, nil: self = .inactive
            }
        case .starting?, .finishing?, nil: self = .inactive
        }
    }

    func barStyle(engine: MicEngineState, rail: ListeningPrivacyRailState, privacy: RailPrivacy?) -> ListeningBarStyle {
        // A running, open input tap stays on air during a USB callback stall because capture can resume.
        guard self != .inactive, engine == .running, rail.kind == .recording else { return .standard }
        switch privacy {
        case .unsupported?: return .onAir
        case .status(let status)?: return status.shown == .confirmedNotPrivate && !status.pending ? .onAir : .standard
        case nil: return .standard
        }
    }
}

struct StationListeningRail {
    let listening: StationMenuStatus.Listening?
    let talk: TalkCapturePhase?
    let host: RailHost

    var capture: StationListeningCapture { StationListeningCapture(listening: listening, talk: talk) }

    func presentation(engine: MicEngineState) -> (state: ListeningPrivacyRailState, style: ListeningBarStyle) {
        // An individual owner's engine cannot prove the whole microphone off.
        let mic = MicLiveInputs(engine: .unknown, ambient: listening, talk: talk).state
        var ambient = listening
        var railHost = host
        if listening == .elsewhere, capture == .talk, engine == .running {
            // The handoff and its stop notice describe the ambient run. Talk has its own local input.
            ambient = .off
            railHost.handoff = nil
            if case .stopped? = railHost.connection { railHost.connection = nil }
        }
        let state = ListeningPrivacyRailState.resolve(mic: mic, listening: ambient, talk: talk, host: railHost)
        return (state, capture.barStyle(engine: engine, rail: state, privacy: host.privacy))
    }
}

enum ListeningBarStyle: Equatable, Sendable {
    case standard, onAir

    // Opaque sRGB #E60020 with white ink in both appearances.
    static let onAirColors = (ink: Color.white, fill: Color(.sRGB, red: 230 / 255, green: 0, blue: 32 / 255))
}

/// The listening/privacy rail (#1115): one compact line that is always visible, with the full reason in the
/// listening/privacy sheet. It renders a `ListeningPrivacyRailState` and has one action: asking for that sheet. It
/// never starts, stops or changes listening, privacy, a target or a route.
///
/// The glyph is the microphone indicator itself, so a private tone never hides a live microphone's red. At ordinary
/// text sizes the rail is at least 44 pt tall; at accessibility sizes it wraps and grows, with no truncation.
struct ListeningPrivacyRailView: View {
    @Environment(\.stationPalette) private var palette
    let state: ListeningPrivacyRailState
    @Binding var isDetailPresented: Bool
    var listeningDevice: String?
    var barStyle: ListeningBarStyle = .standard
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 44

    private struct Announcement: Equatable {
        let kind: ListeningPrivacyRailState.Kind
        let style: ListeningBarStyle
    }

    var body: some View {
        let tone = colors(in: palette)
        Button {
            isDetailPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                MicLiveIndicatorView(state: state.mic)
                Image(systemName: symbol)
                    .foregroundStyle(tone.ink)
                    .imageScale(.medium)
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.tone == .neutral ? palette[.textPrimary] : tone.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tone.ink)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .background(tone.fill, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenSummary). \(state.detail)")
        .accessibilityHint("Shows listening and privacy details")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("station.listening-privacy-rail")
        .onChange(of: Announcement(kind: state.announcementKey, style: barStyle)) {
            AccessibilityNotification.Announcement(spokenSummary).post()
        }
    }

    private var summary: String {
        if state.kind == .off { return "Microphone off" }
        if state.kind == .recording, let listeningDevice { return "Listening on this \(listeningDevice)" }
        return state.summary
    }

    var spokenSummary: String { barStyle == .onAir ? "\(summary), on air" : summary }

    /// A shape per kind, so the meaning never rests on colour alone.
    private var symbol: String {
        if barStyle == .onAir { return "dot.radiowaves.left.and.right" }
        return switch state.kind {
        case .paused: "pause.circle.fill"
        case .mayBeRecording: "exclamationmark.triangle.fill"
        case .recording: "waveform"
        case .privateConfirmed, .privateUnavailable: "lock.fill"
        case .elsewhere: "arrow.right.circle"
        case .interrupted: "wifi.exclamationmark"
        case .off: "mic.slash"
        }
    }

    func colors(in palette: StationPalette) -> (ink: Color, fill: Color) {
        if barStyle == .onAir { return ListeningBarStyle.onAirColors }
        if state.kind == .recording, listeningDevice != nil {
            return (palette[.textPrimary], palette[.surface])
        }
        return switch state.tone {
        case .alert: (palette[.stateLive], palette[.alertSurface])
        case .private: (palette[.statePrivate], palette[.privateSurface])
        case .neutral: (palette[.textSecondary], palette[.surface])
        }
    }
}

#Preview("Listening and privacy rail · synthetic") {
    @Previewable @State var presented = false
    let now = Date()
    let confirmed = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: DuckModeStatus(on: true), requested: nil, now: now))
    let notPrivate = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: DuckModeStatus(on: false), requested: nil, now: now))
    let unavailable = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: DuckModeStatus(on: true), requested: nil, listeningStopped: true, now: now))
    let states: [ListeningPrivacyRailState] = [
        .resolve(mic: nil, listening: nil, talk: .idle, host: RailHost(
            privacy: nil, handoff: nil, availability: .ready, connection: nil)),
        .resolve(mic: .uncertain, listening: .paused, talk: .idle, host: RailHost(
            privacy: notPrivate, handoff: nil, availability: .ready, connection: nil)),
        .resolve(mic: .live, listening: .listening, talk: .idle, host: RailHost(
            privacy: confirmed, handoff: nil, availability: .ready, connection: nil)),
        .resolve(mic: .live, listening: .listening, talk: .idle, host: RailHost(
            privacy: .unsupported, handoff: nil, availability: .ready, connection: nil)),
        .resolve(mic: .off, listening: .off, talk: .idle, host: RailHost(
            privacy: unavailable, handoff: nil, availability: .ready, connection: nil)),
        .resolve(mic: .off, listening: .elsewhere, talk: .idle, host: RailHost(
            privacy: nil, handoff: .movedAway(to: "pad"), availability: .ready, connection: nil)),
        .resolve(mic: .off, listening: .off, talk: .idle, host: RailHost(
            privacy: nil, handoff: nil, availability: .reconnecting, connection: .reconnecting)),
        .resolve(mic: .off, listening: .off, talk: .idle, host: RailHost(
            privacy: notPrivate, handoff: nil, availability: .ready, connection: nil))
    ]
    ScrollView {
        VStack(spacing: 12) {
            ForEach(states, id: \.summary) { state in
                ListeningPrivacyRailView(state: state, isDetailPresented: $presented)
            }
        }
        .padding()
    }
}
