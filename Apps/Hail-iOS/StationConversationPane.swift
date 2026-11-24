import HailCore
import SwiftUI

/// The existing chat still owns its transcript layout, reading position, attribution and playback controls.
struct StationConversationPane: View {
    let root: RootView
    let showsTools: Bool
    let showsRecovery: Bool
    let reviewRecovery: () -> Void
    @Environment(\.stationPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            root.chatSurface
                .frame(minHeight: root.chatThread != nil ? 140 : nil)
            if root.stationAvailability == .unconfigured {
                onboarding
            } else if root.destination == nil {
                root.conversationSurface
            }
            if let reply = root.playback.presentationForControls, root.playback.isPaused,
               let destination = root.destination, root.replyPresentation(for: destination)?.id == reply.id {
                Label("Reply playback is paused", systemImage: "pause.circle")
                    .font(.callout).padding(10)
                    .background(palette[.surface], in: .rect(cornerRadius: 8))
                    .accessibilityIdentifier("station.playback-held")
            }
            if showsRecovery {
                Button("Review recovery options", systemImage: "exclamationmark.triangle", action: reviewRecovery)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("station.review-recovery")
            }
            if showsTools || root.destination == nil {
                root.stationTools
                StationBuildFooter().stationRemovedWhileHidden()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform").font(.title)
                .foregroundStyle(palette[.brand])
                .padding(12).background(palette[.sidebarSelection], in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            Text("A voice connection to your workspace.")
                .font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text("Connect to a Mac running Hailing Station, choose a session, then speak.")
            Text("Microphone access is requested when you start capture.")
                .font(.callout).foregroundStyle(palette[.textSecondary])
            StationToolLink(section: .devices) {
                ConnectivityLabView(store: root.connections, endpointsChanged: root.persist)
            } label: {
                Label("Set up a Mac", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("station.setup-mac")
        }
        .padding(.vertical, 20)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
