import HailCore
import SwiftUI

/// How the station fills the screen (#288). On a regular-width iPad at a non-accessibility text size everything fits
/// one screen: the content is exactly the visible height and the transcript absorbs the slack. Elsewhere it scrolls.
/// The view tree is the same either way, so rotating or resizing never remounts the conversation or ambient card.
struct StationFit {
    let fitsOneScreen: Bool
    /// Wide enough for three columns (an iPad in landscape); otherwise the side columns stack.
    let isWide: Bool
    let height: CGFloat?
}

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return GeometryReader { proxy in
            let fit = stationFit(in: proxy.size)
            ScrollView {
                VStack(spacing: fit.fitsOneScreen ? 14 : 18) {
                    StationHeader(connection: connectionPresentation, compact: fit.fitsOneScreen) {
                        destinationMenu
                    }
                    adaptiveContent(fit)
                }
                .frame(maxWidth: fit.fitsOneScreen ? 1_400 : 1_120)
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, fit.fitsOneScreen ? 12 : 16)
                .frame(maxWidth: .infinity)
                .frame(height: fit.height, alignment: .top)
            }
            .scrollDisabled(fit.fitsOneScreen)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar(UIDevice.current.userInterfaceIdiom == .pad ? .hidden : .automatic, for: .navigationBar)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StationBuildFooter()
        }
        .onAppear { CapturePlaybackSuppression.releaseCompleted(using: playback) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { CapturePlaybackSuppression.releaseCompleted(using: playback) }
        }
    }

    /// Only an iPad with room for the conversation and side columns fits one screen. A large iPhone in landscape
    /// is regular width too, and a short Stage Manager window may be too low; both keep scrolling.
    func stationFit(in size: CGSize) -> StationFit {
        let fits = UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize && size.height >= 600
        return StationFit(fitsOneScreen: fits, isWide: fits && size.width >= 1_100, height: fits ? size.height : nil)
    }

    /// Conversation first; then listening and the current reply; then audio route, tools and diagnostics. Stacked
    /// on iPhone, two columns on an iPad in portrait, three in landscape.
    func adaptiveContent(_ fit: StationFit) -> some View {
        let regular = horizontalSizeClass == .regular
        let layout = regular
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        let side = fit.isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        return layout {
            conversationSurface
                .frame(maxWidth: .infinity, maxHeight: fit.fitsOneScreen ? .infinity : nil, alignment: .top)
            side {
                VStack(spacing: 18) {
                    ambientListeningSurface
                    if let reply = playback.latest {
                        ReplyPlaybackView(reply: reply, playback: playback)
                    }
                }
                // Takes the height left over; a long reply scrolls inside its card.
                .frame(maxWidth: regular ? (fit.isWide ? 340 : 360) : .infinity, alignment: .top)
                Group {
                    // Secondary on the one-screen iPad (#288): when a smaller iPad runs out of height, only this
                    // column scrolls; the conversation, listening and reply never move.
                    if fit.fitsOneScreen {
                        ScrollView { secondaryColumn }
                            .scrollBounceBehavior(.basedOnSize)
                    } else {
                        secondaryColumn
                    }
                }
                .frame(maxWidth: regular ? (fit.isWide ? 300 : 360) : .infinity, alignment: .top)
            }
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
