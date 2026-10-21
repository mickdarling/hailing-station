import HailCore
import SwiftUI

extension RootView {
    @ViewBuilder
    var conversationSurface: some View {
        if let destination {
            TranscriptionLabView(
                audioSession: audioRoutes,
                destinationLabel: destination.label,
                destinationID: ConversationDestinationID(
                    endpointID: destination.hostID, targetID: destination.target.id
                ),
                replyIDs: threadReplyIDs(for: destination),
                replyPlaybackStatus: replyStatus(for: destination),
                selectedReplyID: replyPresentation(for: destination)?.id,
                globalReplyAudioSpeaking: playback.isReplyAudioOutputBusy,
                controlledReplyPlaybackStatus: playback.statusForControls,
                replyFailureStatuses: playback.terminalReplyFailureStatuses,
                onCaptureWillBegin: { tapToTalk(started: true); CapturePlaybackSuppression.begin($0, using: playback) },
                onCaptureDidEnd: {
                    tapToTalk(started: false)
                    CapturePlaybackSuppression.end($0, using: playback, resuming: $1)
                },
                onCaptureTeardownCompleted: {
                    CapturePlaybackSuppression.markCleanupComplete($0, using: playback)
                },
                onFinalized: { text, pasted in
                    try await connections.sendFinalText(
                        text, pasted: pasted, host: destination.hostID, targetID: destination.target.id
                    )
                },
                pasteOffer: PasteOffer(
                    accepts: connections.acceptsPaste(host: destination.hostID, targetID: destination.target.id),
                    refusal: connections.lastPasteRefusal.flatMap { $0.endpointID == destination.hostID ? $0 : nil }
                ),
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
                } else if availability == .unconfigured {
                    NavigationLink {
                        ConnectivityLabView(store: connections, endpointsChanged: persist)
                    } label: {
                        Label("Set up a Mac", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.setup-mac")
                } else {
                    // A real check with a visible result, not only a link to Mac Setup (#385).
                    StationConnectionCheckView(
                        connections: connections,
                        hostIDs: connectionCheckHostIDs,
                        endpointsChanged: persist
                    )
                }
            }
            .padding(24)
            .stationCard(minHeight: horizontalSizeClass == .regular ? 420 : 260)
            // A container, so the buttons inside keep their own identifiers (docs/station-build-footer.md).
            .accessibilityElement(children: .contain)
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

    /// The remembered Mac when it is still configured, otherwise every configured Mac (#385).
    var connectionCheckHostIDs: [HostEndpoint.Identifier] {
        let all = connections.hosts.map(\.id)
        guard let preferred = rememberedSelection?.hostID, all.contains(preferred) else { return all }
        return [preferred]
    }

    var connectionPresentation: StationConnectionPresentation { stationAvailability.badge }

    /// The replies that answer the destination's thread, including another session's reply to a request addressed
    /// from it (#636): what the talk control's arrival tracking and the reply status follow, as the chat shows them.
    func threadReplyIDs(for destination: Destination) -> Set<String> {
        connections.conversation.threadReplyIDs(endpointID: destination.hostID, targetID: destination.target.id,
                                                among: playback.replies, addressed: true)
    }

    func replyPresentation(for destination: Destination) -> ReplyPresentation? {
        let thread = threadReplyIDs(for: destination)
        let matches: (ReplyPresentation) -> Bool = { thread.contains($0.id) }
        if let current = playback.presentationForControls, matches(current) { return current }
        return playback.replies.last(where: matches)
    }

    func replyStatus(for destination: Destination) -> String? {
        guard let reply = replyPresentation(for: destination) else { return nil }
        return playback.status(for: reply)
    }

    @MainActor
    func resetStationStateForUITestingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-reset-station-state"),
              !StationUITestReset.didRun else { return }
        StationUITestReset.didRun = true
        UserDefaults.standard.removeObject(forKey: "hailing-station.host-endpoints.v1")
        UserDefaults.standard.removeObject(forKey: "hailing-station.destination-selection.v1")
        diagnostics.setEnabled(false)
    }
}
