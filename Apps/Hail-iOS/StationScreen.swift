import HailCore
import SwiftUI

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return Group {
            if StationRedesignLaunch.flags.isOn(.shell) {
                StationScreen(root: self)
            } else {
                classicStation
            }
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
}

/// Only presentation state lives here. The permanent detail hosts the conversation, talk owner and ambient
/// card in fixed slots even while listening details, sheets or another section cover them.
struct StationScreen: View {
    let root: RootView
    @State private var listeningDetails = false
    @State private var sheet: Sheet?
    @State private var afterRecovery: RecoveryIntent?
    @State private var report: StationTalkReport?
    @State private var dockHeight: CGFloat = 64
    @Environment(\.stationPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Sheet: String, Identifiable {
        case recovery, routes
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                GeometryReader { space in
                    ScrollView {
                        VStack(spacing: 0) {
                            header
                            Divider()
                            root.stationRail(talk: talkPhase, details: $listeningDetails)
                            root.ambientListeningSurface.stationCollapsed(!listeningDetails)
                            Divider()
                            pane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(height: fitsPane ? max(280, space.size.height) : nil)
                        .frame(minHeight: space.size.height, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                // At AX sizes and in short windows the dock can grow beyond the remaining height.
                // One permanent scroll container keeps all actions reachable without replacing the owner.
                ScrollView {
                    dock.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(dockHeight, max(90, viewport.size.height * 0.5)))
            }
        }
        .background(palette[.elevatedSurface])
        .onPreferenceChange(StationTalkReportKey.self) { report = $0 }
        .sheet(item: $sheet, onDismiss: completeRecoveryIntent) { selection in
            NavigationStack {
                Group {
                    switch selection {
                    case .routes: root.audioSettingsOverview.navigationTitle("Audio routes")
                    case .recovery:
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            RecoverySheetView(state: root.recoveryState(at: tick.date, turn: report?.turn)) {
                                afterRecovery = $0
                                sheet = nil
                            }
                        }
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .frame(minWidth: 280, minHeight: 320)
        }
    }

    private var fitsPane: Bool {
        root.destination != nil && !listeningDetails && !typeSize.isAccessibilitySize
    }

    private var talkPhase: TalkCapturePhase? {
        root.destination == nil ? .idle : report?.phase
    }

    private var header: some View {
        HStack(spacing: 0) {
            StationScreenHeader(destination: root.screenDestination, availability: root.stationAvailability,
                                showingDestinations: root.$showingDestinations, browser: { root.destinationBrowser })
            if root.chatThread != nil || root.navigation.fullConversation {
                StationExpandToggle(expanded: Binding(get: { root.navigation.fullConversation }, set: { expanded in
                    if expanded != root.navigation.fullConversation { root.navigation.apply(.toggleFullConversation) }
                }))
                .padding(.trailing, 12)
            }
        }
    }

    private var pane: some View {
        StationConversationPane(root: root, showsTools: listeningDetails, showsRecovery: showRecovery) {
            sheet = .recovery
        }
    }

    private var showRecovery: Bool {
        if root.hasListeningRecovery { return true }
        switch root.stationAvailability {
        case .reconnecting, .offline, .failed, .selectionFailed: return true
        default: break
        }
        switch report?.turn {
        case .noReplyYet, .refused, .sentUnverified, .notSent: return true
        default: return false
        }
    }

    @ViewBuilder private var dock: some View {
        if let destination = root.destination {
            let shownHost = root.connections.snapshots[destination.hostID]
            root.stationTranscription(for: destination).renderingDock { owner in
                AnyView(StationTalkDock(owner: owner, destination: root.screenDestination,
                    onPrivacy: {
                        if let intent = root.stationPrivacyIntent(),
                           case .privacy(_, let host, let generation) = intent,
                           host == shownHost?.id, generation == shownHost?.connectionGeneration {
                            root.performPrivacySettings(intent)
                        } else { listeningDetails = true }
                    }, onListening: { listeningDetails = true }, onRoutes: { sheet = .routes }))
            }
        } else {
            VoiceDockView(state: .resolve(talk: TalkActivity(phase: .idle, sendPending: false, interrupting: false),
                                          destination: root.screenDestination,
                                          accessories: DockAccessories(escape: false, privacy: false, paste: false)),
                          caption: nil) { intent in
                switch intent {
                case .listeningControls: listeningDetails = true
                case .audioRoutes: sheet = .routes
                default: break
                }
            }
        }
    }

    private func completeRecoveryIntent() {
        defer { afterRecovery = nil }
        switch afterRecovery {
        case .inspectConnection: root.navigation.apply(.select(.devices))
        case .chooseDestination: root.showingDestinations = true
        case .openListening: listeningDetails = true
        case nil: break
        }
    }
}
