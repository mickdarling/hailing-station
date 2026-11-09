import HailCore
import SwiftUI

/// The listening/privacy rail (#1115): one compact line that is always visible, with the full reason in the
/// listening/privacy sheet. It renders a `ListeningPrivacyRailState` and has one action: asking for that sheet. It
/// never starts, stops or changes listening, privacy, a target or a route.
///
/// The glyph is the microphone indicator itself, so a private tone never hides a live microphone's red. At ordinary
/// text sizes the rail is at least 44 pt tall; at accessibility sizes it wraps and grows, with no truncation.
struct ListeningPrivacyRailView: View {
    let state: ListeningPrivacyRailState
    @Binding var isDetailPresented: Bool
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 44
    @State private var announced: ListeningPrivacyRailState.Kind?

    var body: some View {
        Button {
            isDetailPresented = true
        } label: {
            HStack(spacing: 10) {
                MicLiveIndicatorView(state: state.mic)
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.medium)
                Text(state.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.tone == .neutral ? Color.primary : tint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .background(tint.opacity(state.tone == .neutral ? 0.06 : 0.12), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint("Shows listening and privacy details")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("station.listening-privacy-rail")
        .onAppear { announced = state.announcementKey }
        .onChange(of: state.announcementKey) { _, key in
            // Only a change of kind is announced, and only once; the first appearance is not.
            guard announced != key else { return }
            announced = key
            AccessibilityNotification.Announcement(state.summary).post()
        }
    }

    /// A shape per kind, so the meaning never rests on colour alone.
    private var symbol: String {
        switch state.kind {
        case .paused: "pause.circle.fill"
        case .mayBeRecording: "exclamationmark.triangle.fill"
        case .recording: "waveform"
        case .privateConfirmed, .privateUnavailable: "lock.fill"
        case .elsewhere: "arrow.right.circle"
        case .interrupted: "wifi.exclamationmark"
        case .off: "mic.slash"
        }
    }

    private var tint: Color {
        switch state.tone {
        case .alert: .red
        case .private: .indigo
        case .neutral: .secondary
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
