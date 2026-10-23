import HailCore
import SwiftUI

// The full-screen conversation (#819): the chat takes the whole station, with only what must stay reachable: a slim
// header (the destination, and a way back to the ambient card while it listens), the privacy switch (#735 S-6), and
// Tap to talk in one row. Surfaces that own audio stay mounted, so removing the ambient card never ends listening and
// removing Tap to talk never ends a capture. It applies only while there is a chat to carry the toggle.

/// Where the device remembers the choice, in its own defaults.
private let stationExpansionKey = "station.chatExpanded"
@MainActor private var stationExpansionWasReset = false

private struct StationCompactTalkKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Tap to talk shows only what must stay reachable (#819). Only the station sets it; Labs never does.
    var stationCompactTalk: Bool {
        get { self[StationCompactTalkKey.self] }
        set { self[StationCompactTalkKey.self] = newValue }
    }
}

/// Holds the device's remembered choice (#819) and hands the station a binding to it. A UI-test reset
/// (`-reset-station-state`) clears it once per launch, so each test starts with the station showing.
struct StationExpansionReader<Content: View>: View {
    @AppStorage(stationExpansionKey) private var expanded = false
    let content: (Binding<Bool>) -> Content

    /// The UI-test reset runs here, before the first frame reads the choice, so a stored value never renders.
    init(@ViewBuilder content: @escaping (Binding<Bool>) -> Content) {
        if !stationExpansionWasReset, ProcessInfo.processInfo.arguments.contains("-reset-station-state") {
            stationExpansionWasReset = true // Once per process.
            UserDefaults.standard.removeObject(forKey: stationExpansionKey)
        }
        self.content = content
    }

    var body: some View { content($expanded) }
}

/// Expands the conversation to the whole station, or brings the station back (#819). On the Mac, Shift-Command-E.
struct StationExpandToggle: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .accessibilityLabel(expanded ? "Show the station" : "Expand the conversation")
        .accessibilityHint(expanded ? "Brings back the station cards." : "Makes the conversation fill the screen.")
        .accessibilityIdentifier("station.chat-expand")
    }
}

/// Pinch out on the chat to expand it, pinch in to bring the station back (#819). Simultaneous, so scrolling, the
/// time-reveal swipe and the context menu are untouched.
struct StationExpandPinch: ViewModifier {
    @Binding var expanded: Bool
    /// Off where there is no chat to expand.
    let enabled: Bool

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture().onEnded { value in
                guard enabled else { return }
                if !expanded, value.magnification > 1.2 { withAnimation { expanded = true } }
                if expanded, value.magnification < 0.83 { withAnimation { expanded = false } }
            }
        )
    }
}

/// The header while the conversation is full screen (#819 review): one slim row, the destination, a listening chip that
/// brings the station back so listening can be stopped, and the connection, instead of the tall station header.
struct StationExpandedHeader<Picker: View>: View {
    let connection: StationConnectionPresentation
    /// The ambient controller's own listening state (#282).
    let listening: Bool
    @Binding var expanded: Bool
    @ViewBuilder let picker: Picker

    var body: some View {
        HStack(spacing: 10) {
            picker.frame(maxWidth: 560)
            Spacer(minLength: 0)
            if listening {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
                } label: {
                    Label("Listening", systemImage: "waveform").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Listening · Show controls")
                .accessibilityHint("Brings back the station, where listening can be stopped.")
                .accessibilityIdentifier("station.expanded-listening")
            }
            Image(systemName: connection.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(connection.color)
                .accessibilityLabel("Connection status: \(connection.label)")
                .accessibilityIdentifier("station.connection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension RootView {
    /// The chat above Tap to talk, and, while the conversation is full screen (#819), what must stay reachable.
    func primaryColumn(_ fit: StationFit, expanded: Binding<Bool>) -> some View {
        let isExpanded = expanded.wrappedValue
        let listening = connections.ambientStreaming
        // Stacked, or Tap to talk beside the chat in landscape (#819 review). The same slots either way, so
        // switching never remounts Tap to talk.
        let layout = fit.beside
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(spacing: isExpanded ? 12 : 18))
        return layout {
            if !fit.isWide {
                expandableChat(expanded)
                    .frame(height: fit.fitsOneScreen ? nil : 340)
                    .layoutPriority(1)
            }
            // Beside the chat the column can run out of height, so it scrolls there; elsewhere it keeps its own height.
            // One wrapper in every mode, so rotating never remounts Tap to talk.
            ScrollView {
                VStack(spacing: 12) {
                    // First, so a short column never cuts it off; the ambient card's own condition (#735 S-6).
                    if isExpanded, let host = seedsTalk ? StationUITestSeed.hostID : destination?.hostID,
                       seedsTalk || connections.showsPrivacySwitch(host, listening: listening) {
                        PrivacySwitchView(connections: connections, hostID: host, listening: listening)
                    }
                    // With no destination there is nothing to talk to: the setup panel steps aside too.
                    talkSurface
                        .environment(\.stationCompactTalk, isExpanded)
                        .stationCollapsed(isExpanded && !hasTalk)
                }
            }
            .scrollDisabled(!fit.beside)
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: !fit.beside)
            .frame(width: fit.beside && hasTalk ? 300 : nil) // Empty, and so narrow, with no destination.
        }
    }

    /// DEBUG UI tests only (#819 review): `-seed-talk-card` shows an invented Tap to talk and privacy switch with no
    /// destination, so the full-screen layout is measured with both present. Nothing in release.
    private var seedsTalk: Bool {
        #if DEBUG
        destination == nil && ProcessInfo.processInfo.arguments.contains("-seed-talk-card")
        #else
        false
        #endif
    }
    private var hasTalk: Bool { destination != nil || seedsTalk }

    @ViewBuilder private var talkSurface: some View {
        if seedsTalk {
            TranscriptionLabView(audioSession: audioRoutes, destinationLabel: "Invented Mac", onFinalized: { _, _ in })
        } else {
            conversationSurface
        }
    }

    /// The chat with its full-screen toggle and pinch (#819). Only on the chat itself (#819 review): on a held reply's
    /// card, with no chat to expand, a toggle would do nothing but quietly change the remembered choice.
    func expandableChat(_ expanded: Binding<Bool>) -> some View {
        let hasChat = chatThread != nil
        return chatSurface
            // Beside the "Conversation" title, clear of the newest message (#819 review).
            .overlay(alignment: .topTrailing) {
                if hasChat { StationExpandToggle(expanded: expanded).padding(8) }
            }
            .modifier(StationExpandPinch(expanded: expanded, enabled: hasChat))
    }
}

extension View {
    /// Keeps a surface mounted, and so running, while the conversation is full screen, but takes no space, cannot be
    /// seen or tapped, and is left out for VoiceOver (#819).
    @ViewBuilder
    func stationCollapsed(_ collapsed: Bool) -> some View {
        frame(width: collapsed ? 0 : nil, height: collapsed ? 0 : nil)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}
