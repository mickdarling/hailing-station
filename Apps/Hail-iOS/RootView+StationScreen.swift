import HailCore
import SwiftUI

extension RootView {
    var redesignedStation: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            stationScreen(privacy: stationPrivacy(at: tick.date))
        }
    }

    private func stationScreen(privacy: StationScreenPrivacy) -> some View {
        StationScreen(hasDestination: destination != nil, needsRecovery: needsStationRecovery,
            header: { screenHeader }, listening: { phase, details in
                stationRail(talk: phase, details: details, privacy: privacy)
                ambientListeningSurface.stationCollapsed(!details.wrappedValue)
            }, pane: { details, recovery, review in
                StationConversationPane(hasThread: chatThread != nil, needsSetup: stationAvailability == .unconfigured,
                    playbackHeld: selectedPlaybackHeld, chat: stationDocument,
                    fallback: { if destination == nil { conversationSurface } }, tools: { stationTools },
                    openDevices: openDevices, showsTools: details || destination == nil,
                    showsRecovery: recovery, reviewRecovery: review)
            }, dock: { listening, routes in
                screenDock(privacy: privacy, showListening: listening, showRoutes: routes)
            },
            routes: { audioSettingsOverview }, recoveryState: recoveryState,
            inspectConnection: openDevices, chooseDestination: { showingDestinations = true })
            #if STATION_UI_FIXTURES
            .task(id: chatThread?.targetID) {
                if chatThread != nil { await seedChatIfRequested() }
            }
            #endif
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
    private func screenDock(privacy: StationScreenPrivacy, showListening: @escaping () -> Void,
                            showRoutes: @escaping () -> Void) -> some View {
        if let destination {
            let generation = connections.snapshots[destination.hostID]?.connectionGeneration
            let stillDisplayed = {
                self.destination == destination && connections.snapshots[destination.hostID]?.connectionGeneration
                    == generation
            }
            stationTranscription(for: destination).renderingDock(StationDockControls(
                destination: { stillDisplayed() ? screenDestination : .none },
                privacy: privacy.dockEnabled ? {
                    guard stillDisplayed() else { return }
                    if privacy.intent != nil {
                        activateStationPrivacy(privacy)
                    } else if stationPrivacy() == privacy {
                        showListening()
                    }
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
