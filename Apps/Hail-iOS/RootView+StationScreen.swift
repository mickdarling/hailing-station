import HailCore
import SwiftUI

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return Group {
            if StationRedesignLaunch.flags.isOn(.shell) {
                redesignedStation
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

    private var redesignedStation: some View {
        StationScreen(hasDestination: destination != nil, needsRecovery: needsStationRecovery,
            header: { screenHeader }, listening: { phase, details in
                stationRail(talk: phase, details: details)
                ambientListeningSurface.stationCollapsed(!details.wrappedValue)
            }, pane: { details, recovery, review in
                StationConversationPane(hasThread: chatThread != nil, needsSetup: stationAvailability == .unconfigured,
                    playbackHeld: selectedPlaybackHeld, chat: { chatSurface },
                    fallback: { if destination == nil { conversationSurface } }, tools: { stationTools },
                    openDevices: openDevices, showsTools: details || destination == nil,
                    showsRecovery: recovery, reviewRecovery: review)
            }, dock: { listening, routes in screenDock(showListening: listening, showRoutes: routes) },
            routes: { audioSettingsOverview }, recoveryState: recoveryState,
            inspectConnection: openDevices, chooseDestination: { showingDestinations = true })
            #if os(macOS)
            .stationBuildFooter()
            #endif
    }

    private func openDevices() { navigation.apply(.select(.devices)) }

    private var selectedPlaybackHeld: Bool {
        guard playback.isPaused, let reply = playback.presentationForControls, let destination else { return false }
        return replyPresentation(for: destination)?.id == reply.id
    }

    private var needsStationRecovery: Bool {
        if hasListeningRecovery { return true }
        switch stationAvailability {
        case .reconnecting, .offline, .failed, .selectionFailed: return true
        default: return false
        }
    }

    private var screenHeader: some View {
        HStack(spacing: 0) {
            StationScreenHeader(destination: screenDestination, availability: stationAvailability,
                                showingDestinations: $showingDestinations, browser: { destinationBrowser })
            if chatThread != nil || navigation.fullConversation {
                StationExpandToggle(expanded: Binding(get: { navigation.fullConversation }, set: { expanded in
                    if expanded != navigation.fullConversation { navigation.apply(.toggleFullConversation) }
                }))
                .padding(.trailing, 12)
            }
        }
    }

    @ViewBuilder
    private func screenDock(showListening: @escaping () -> Void, showRoutes: @escaping () -> Void) -> some View {
        if let destination {
            let generation = connections.snapshots[destination.hostID]?.connectionGeneration
            let privacy = stationPrivacy()
            stationTranscription(for: destination).renderingDock(StationDockControls(
                destination: {
                    guard self.destination?.hostID == destination.hostID, self.destination?.target.id == destination.target.id,
                          connections.snapshots[destination.hostID]?.connectionGeneration == generation else { return .none }
                    return screenDestination
                }, privacy: privacy.dockEnabled ? {
                    if privacy.intent != nil { activateStationPrivacy(privacy) }
                    else if stationPrivacy() == privacy { showListening() }
                } : nil, listening: showListening, routes: showRoutes))
        } else {
            VoiceDockView(state: .resolve(talk: TalkActivity(phase: .idle, sendPending: false, interrupting: false),
                                          destination: screenDestination,
                                          accessories: DockAccessories(escape: false, privacy: false, paste: false)),
                          caption: nil) { intent in
                switch intent {
                case .listeningControls: showListening()
                case .audioRoutes: showRoutes()
                default: break
                }
            }
        }
    }
}
