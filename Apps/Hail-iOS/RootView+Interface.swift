import HailCore
import SwiftUI

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return ScrollView {
            VStack(spacing: 18) {
                StationHeader(connection: connectionPresentation) {
                    destinationMenu
                }
                adaptiveContent
            }
            .frame(maxWidth: 1_120)
            .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { CapturePlaybackSuppression.releaseCompleted(using: playback) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { CapturePlaybackSuppression.releaseCompleted(using: playback) }
        }
    }

    var adaptiveContent: some View {
        let layout = horizontalSizeClass == .regular
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        return layout {
            VStack(spacing: 18) {
                conversationSurface
                if let reply = playback.latest {
                    ReplyPlaybackView(reply: reply, playback: playback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 18) {
                AudioRouteSummaryView(model: audioRoutes)
                stationTools
            }
            .frame(maxWidth: horizontalSizeClass == .regular ? 360 : .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    var conversationSurface: some View {
        if let destination {
            TranscriptionLabView(
                audioSession: audioRoutes,
                destinationLabel: destination.label,
                destinationID: ConversationDestinationID(
                    endpointID: destination.hostID, targetID: destination.target.id
                ),
                replyIDs: Set(playback.replies.lazy.filter { reply in
                    reply.endpointID == destination.hostID && reply.target == destination.target.id
                }.map(\.id)),
                replyPlaybackStatus: replyStatus(for: destination),
                globalReplyAudioSpeaking: playback.isReplyAudioOutputBusy,
                onCaptureWillBegin: { CapturePlaybackSuppression.begin($0, using: playback) },
                onCaptureDidEnd: { CapturePlaybackSuppression.end($0, using: playback, resuming: $1) },
                onCaptureTeardownCompleted: {
                    CapturePlaybackSuppression.markCleanupComplete($0, using: playback)
                },
                onFinalized: { text in
                    try await connections.sendFinalText(
                        text, host: destination.hostID, targetID: destination.target.id
                    )
                },
                onEscape: {
                    try await connections.sendEscape(
                        host: destination.hostID, targetID: destination.target.id
                    )
                }
            )
        } else {
            let availability = stationAvailability
            VStack(spacing: 16) {
                if availability.isWorking {
                    ProgressView().accessibilityHidden(true)
                }
                Image(systemName: availability.badge.systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(availability.emptyTitle)
                    .font(.title3.bold())
                Text(availability.emptyDetail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if availability.canChooseDestination {
                    Button {
                        showingDestinations = true
                    } label: {
                        Label("Choose a destination", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.choose-destination")
                } else {
                    NavigationLink {
                        ConnectivityLabView(store: connections, endpointsChanged: persist)
                    } label: {
                        Label(
                            availability == .unconfigured ? "Set up a Mac" : "Check Mac connection",
                            systemImage: availability == .unconfigured ? "plus.circle.fill" : "network"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.setup-mac")
                }
            }
            .padding(24)
            .stationCard(minHeight: horizontalSizeClass == .regular ? 420 : 260)
            .accessibilityIdentifier("station.availability")
        }
    }
    var stationTools: some View {
        GroupBox {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { toolLinks }
                VStack(spacing: 10) { toolLinks }
            }
            .buttonStyle(.bordered)
        } label: {
            Label("Station tools", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .accessibilityIdentifier("station.tools")
    }

    @ViewBuilder
    var toolLinks: some View {
        NavigationLink {
            ConnectivityLabView(store: connections, endpointsChanged: persist)
        } label: {
            Label("Mac Setup", systemImage: "network")
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("station.mac-setup-tool")
        NavigationLink {
            AudioDiagnosticsView(model: audioRoutes)
        } label: {
            Label("Audio", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        NavigationLink {
            CaptureSafeLabsView(audioSession: audioRoutes, playback: playback)
        } label: {
            Label("Labs", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity)
        }
    }

    var stationAvailability: StationAvailability {
        StationAvailability.resolve(
            hosts: connections.hosts,
            preferredHostID: rememberedSelection?.hostID,
            selectionConfirmed: destination != nil,
            hasRememberedSelection: rememberedSelection != nil,
            selectionInProgress: isRestoringSelection
        )
    }

    var connectionPresentation: StationConnectionPresentation { stationAvailability.badge }

    func replyStatus(for destination: Destination) -> String? {
        let matches: (ReplyPresentation) -> Bool = {
            $0.endpointID == destination.hostID && $0.target == destination.target.id
        }
        if let current = playback.presentationForControls, matches(current) {
            return playback.status(for: current)
        }
        guard let latest = playback.replies.last(where: matches) else { return nil }
        return playback.status(for: latest)
    }

    @MainActor
    private func resetStationStateForUITestingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-reset-station-state"),
              !StationUITestReset.didRun else { return }
        StationUITestReset.didRun = true
        UserDefaults.standard.removeObject(forKey: "hailing-station.host-endpoints.v1")
        UserDefaults.standard.removeObject(forKey: "hailing-station.destination-selection.v1")
    }
}
