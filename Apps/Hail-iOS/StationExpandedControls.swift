import HailCore
import SwiftUI

// The full-screen conversation (#819): the chat takes the whole station, and only what must stay reachable is shown
// beside it: talk or stop (the same Tap to talk, without its paste offer), the privacy switch and indicator
// (#735 S-6), and, while ambient listening is on, a way back to its card. Surfaces that own audio stay mounted, so
// nothing they own stops: removing the ambient card would end listening, and removing Tap to talk would end a
// capture. It applies only while there is a chat to carry the toggle.

/// Where the device remembers the choice, in its own defaults.
private let stationExpansionKey = "station.chatExpanded"

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
        if StationExpansionReset.consume() { UserDefaults.standard.removeObject(forKey: stationExpansionKey) }
        self.content = content
    }

    var body: some View { content($expanded) }
}

/// Runs the UI-test reset of the remembered choice once per process.
@MainActor
private enum StationExpansionReset {
    static var didRun = false

    static func consume() -> Bool {
        guard !didRun, ProcessInfo.processInfo.arguments.contains("-reset-station-state") else { return false }
        didRun = true
        return true
    }
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

/// What stays beside the full-screen conversation besides Tap to talk (#819): the privacy switch, under exactly the
/// condition the ambient card uses, and a listening chip that brings the station back so listening can be stopped.
struct StationExpandedBar: View {
    let connections: HostConnectionStore
    let hostID: HostEndpoint.Identifier?
    @Binding var expanded: Bool

    var body: some View {
        let listening = connections.ambientStreaming
        VStack(alignment: .leading, spacing: 10) {
            // `ambientStreaming` is the ambient controller's own listening state (#282); PRIVATE still comes only
            // from the host's confirmed notice inside the switch (#735 S-6).
            if let hostID, connections.showsPrivacySwitch(hostID, listening: listening) {
                PrivacySwitchView(connections: connections, hostID: hostID, listening: listening)
            }
            if listening {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
                } label: {
                    Label("Listening · Show controls", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Brings back the station, where listening can be stopped.")
                .accessibilityIdentifier("station.expanded-listening")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RootView {
    /// The chat above Tap to talk, and, while the conversation is full screen (#819), what must stay reachable.
    func primaryColumn(_ fit: StationFit, expanded: Binding<Bool>) -> some View {
        let isExpanded = expanded.wrappedValue
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
            VStack(spacing: 12) {
                // With no destination there is nothing to talk to: the setup panel steps aside too, until collapsing.
                conversationSurface
                    .environment(\.stationCompactTalk, isExpanded)
                    .stationCollapsed(isExpanded && destination == nil)
                if isExpanded {
                    StationExpandedBar(connections: connections, hostID: destination?.hostID, expanded: expanded)
                }
            }
            .frame(width: fit.beside && destination != nil ? 300 : nil) // Empty, and so narrow, with no destination.
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
