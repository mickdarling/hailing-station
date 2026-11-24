import HailCore
import SwiftUI

/// The existing chat still owns its transcript layout, reading position, attribution and playback controls.
struct StationConversationPane<Chat: View, Fallback: View, Tools: View>: View {
    let hasThread: Bool
    let needsSetup: Bool
    let playbackHeld: Bool
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let fallback: () -> Fallback
    @ViewBuilder let tools: () -> Tools
    let openDevices: () -> Void
    let showsTools: Bool
    let showsRecovery: Bool
    let reviewRecovery: () -> Void
    @Environment(\.stationPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chat()
                .frame(minHeight: hasThread ? 140 : nil)
            if needsSetup {
                onboarding
            } else {
                fallback()
            }
            if playbackHeld {
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
            if showsTools {
                tools()
                #if !os(macOS)
                StationBuildFooter().stationRemovedWhileHidden()
                #endif
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
            Button(action: openDevices) {
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
