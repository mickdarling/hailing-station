import HailCore
import SwiftUI

/// How the station fills the screen (#288). On a regular-width iPad at a non-accessibility text size everything fits
/// one screen: the content is exactly the visible height and the chat absorbs the slack. Elsewhere it scrolls.
/// The view tree is the same either way, so rotating or resizing never remounts the conversation or ambient card.
struct StationFit {
    let fitsOneScreen: Bool
    /// Wide enough for three columns (an iPad in landscape); otherwise the side columns stack.
    let isWide: Bool
    let height: CGFloat?
    /// The denser type of the one-screen iPad (#288). It follows the device's normal layout, so expanding the
    /// conversation (#819) never changes the text size.
    let denseType: Bool
    /// The full-screen conversation on a screen wider than tall (#819 review): Tap to talk sits beside the chat, so
    /// a landscape iPhone keeps its height for the chat.
    let beside: Bool
    /// The chat's height when the station scrolls: larger while full screen at accessibility sizes (#819 review).
    var chatHeight: CGFloat = 340
}

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return StationExpansionReader { stored in GeometryReader { proxy in
            // Full screen only while there is a chat, which carries the toggle (#819 review): with no chat (a cold
            // launch before the host is ready, an unconfigured or unreachable Mac) the station shows, whatever the
            // device remembers, so setup and the way back are never hidden.
            let expanded = Binding(get: { stored.wrappedValue && chatThread != nil }, set: { stored.wrappedValue = $0 })
            let fit = stationFit(in: proxy.size, expanded: expanded.wrappedValue)
            ScrollView {
                VStack(spacing: fit.fitsOneScreen ? 14 : 18) {
                    // Full screen, a slim header (#819 review). Otherwise the one-row header only where the device's
                    // normal layout has room. Neither holds state, so switching remounts nothing that matters.
                    if expanded.wrappedValue {
                        StationExpandedHeader(connection: connectionPresentation,
                                              listening: connections.ambientStreaming, expanded: expanded) {
                            destinationMenu
                        }
                    } else {
                        StationHeader(connection: connectionPresentation, compact: fit.denseType) { destinationMenu }
                    }
                    adaptiveContent(fit, expanded: expanded)
                }
                .frame(maxWidth: fit.fitsOneScreen ? 1_400 : 1_120)
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, fit.fitsOneScreen ? 12 : 16)
                .frame(maxWidth: .infinity)
                .frame(height: fit.height, alignment: .top)
                .environment(\.dynamicTypeSize, stationTypeSize(fit))
            }
            .scrollBounceBehavior(.basedOnSize)
            .stationDismissKeyboardOnScroll()
        } }
        // The station header names the app; a "Conversation" bar above it only costs height (#288).
        .stationHiddenNavigationBar()
        .background(StationPlatform.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StationBuildFooter()
        }
        .onAppear {
            // Weak, and never cleared on disappear: a pushed tool screen hides this view while its heals still count,
            // and a scene that goes without `onDisappear` leaves nothing alive here (#763 review).
            CapturePlaybackSuppression.reportHeals(for: playback) { [weak diagnostics] in
                Self.logHeal($0, to: diagnostics)
            }
            CapturePlaybackSuppression.releaseCompleted(using: playback)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { CapturePlaybackSuppression.releaseCompleted(using: playback) }
        }
        // A reply arriving also drops any capture hold left with no live capture, so it never queues silently (#760).
        .onChange(of: playback.latest?.id) { _, _ in
            guard scenePhase == .active || connections.ambientStreaming else { return }
            CapturePlaybackSuppression.reconcile(using: playback)
        }
    }

    /// Only an iPad with room for the conversation and side columns fits one screen. A large iPhone in landscape
    /// is regular width too, and a short Stage Manager window may be too low; both keep scrolling. The full-screen
    /// conversation (#819) always fills exactly the visible height, on every device, with the chat in the first column.
    func stationFit(in size: CGSize, expanded: Bool) -> StationFit {
        let fits = StationPlatform.supportsWideLayout && horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize && size.height >= 600
        if expanded {
            // At accessibility sizes, or on a short portrait screen such as an iPhone SE, nothing fits one screen (#819
            // review): the chat takes most of it, and the station scrolls to Tap to talk below.
            let scrolls = dynamicTypeSize.isAccessibilitySize || (size.height < 700 && size.width <= size.height)
            return StationFit(
                fitsOneScreen: !scrolls, isWide: false, height: scrolls ? nil : size.height, denseType: fits,
                beside: !scrolls && size.width > size.height, chatHeight: max(340, size.height * 0.7)
            )
        }
        return StationFit(
            fitsOneScreen: fits, isWide: fits && size.width >= 1_150, height: fits ? size.height : nil, denseType: fits,
            beside: false
        )
    }

    /// The station reads denser than the system default (#288, Mick: "the fonts are just too big"): two steps
    /// smaller on the one-screen iPad, one on iPhone, relative to the user's setting. Accessibility sizes are kept.
    func stationTypeSize(_ fit: StationFit) -> DynamicTypeSize {
        guard !dynamicTypeSize.isAccessibilitySize else { return dynamicTypeSize }
        let sizes = DynamicTypeSize.allCases
        guard let index = sizes.firstIndex(of: dynamicTypeSize) else { return dynamicTypeSize }
        return sizes[max(sizes.startIndex, index - (fit.denseType ? 2 : 1))]
    }

    /// Conversation first; then listening and the current reply; then audio route, tools and diagnostics. Stacked
    /// on iPhone, two columns on an iPad in portrait, three in landscape.
    func adaptiveContent(_ fit: StationFit, expanded: Binding<Bool>) -> some View {
        let regular = horizontalSizeClass == .regular
        let collapsed = expanded.wrappedValue
        let layout = regular
            ? AnyLayout(HStackLayout(alignment: .top, spacing: collapsed ? 0 : 18))
            : AnyLayout(VStackLayout(spacing: collapsed ? 0 : 18))
        let side = fit.isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        return layout {
            // The chat sits above Tap to talk in portrait and on iPhone, and beside it in landscape (#288). Each
            // position is a fixed slot, so moving the chat never remounts the conversation or the ambient card.
            primaryColumn(fit, expanded: expanded)
                .frame(maxWidth: .infinity, maxHeight: fit.fitsOneScreen ? .infinity : nil, alignment: .top)
            side {
                VStack(spacing: 18) {
                    listeningSurfaces
                    if fit.isWide { expandableChat(expanded) }
                }
                .frame(maxWidth: regular ? (fit.isWide ? 420 : 360) : .infinity, alignment: .top)
                Group {
                    // Secondary on the one-screen iPad (#288): when a smaller iPad runs out of height, only this
                    // column scrolls; the conversation, listening and chat never move.
                    if fit.fitsOneScreen {
                        ScrollView { secondaryColumn }
                            .scrollBounceBehavior(.basedOnSize)
                    } else {
                        secondaryColumn
                    }
                }
                .frame(maxWidth: regular ? (fit.isWide ? 280 : 360) : .infinity, alignment: .top)
            }
            // Mounted but out of sight while the conversation is full screen (#819): the ambient card keeps listening
            // and its stop is one tap away, through the listening chip.
            .stationCollapsed(collapsed)
        }
    }

    /// Private coaching, then ambient listening. The Mac drafts put their coaching card in this slot (#504); iPhone
    /// and iPad show it disabled until #604 lands (#611).
    @ViewBuilder
    private var listeningSurfaces: some View {
        // The Mac shows no coaching card until its own private coaching card is ported (#266).
        #if !os(macOS)
        CoachingUnavailableCard()
        #endif
        ambientListeningSurface
    }

    /// The chat for the confirmed destination. Without one, the latest reply keeps its own card so its playback
    /// controls are never out of reach.
    @ViewBuilder
    var chatSurface: some View {
        if let thread = chatThread {
            ConversationChatView(
                // With another session's reply to a request addressed from this thread, labelled (#636).
                entries: connections.conversation.entries(
                    endpointID: thread.hostID, targetID: thread.targetID, addressed: true
                ),
                threadTargetID: thread.targetID,
                playback: playback
            )
            .task { await StationUITestSeed.runIfRequested(into: connections) } // DEBUG UI tests only (#717).
        } else if let reply = playback.latest {
            ReplyPlaybackView(reply: reply, playback: playback)
        }
    }

    /// Audio route, station tools and diagnostics.
    var secondaryColumn: some View {
        VStack(spacing: 18) {
            AudioRouteSummaryView(model: audioRoutes)
            stationTools
            DiagnosticsLoggingCard(diagnostics: diagnostics, collectingHost: connections.diagnosticsCollectingHost)
        }
    }
}
