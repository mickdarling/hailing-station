#if os(macOS)
import SwiftUI
@testable import HailCore

@MainActor
final class NativeSettingsGalleryIntents {
    private(set) var invocationCount = 0
    func record() { invocationCount += 1 }
}

/// Authored input values, not installed-app or hardware readings. Every renderer is the actual app source.
enum NativeSettingsGalleryPage: String, CaseIterable {
    case audio, privacy, advanced, voices, targets, listening, notifications

    @MainActor
    func scene(intents: NativeSettingsGalleryIntents) -> AnyView {
        switch self {
        case .audio: audio()
        case .privacy: privacy(intents)
        case .advanced: advanced(intents)
        case .voices:
            AnyView(VoicesSettingsView(settings: ReplySegmentSettings(
                pauseAfterSegment: 2.5, sustainedOnset: 0.05, onsetThresholdDBFS: -32.5
            )) { tools(["Turn-taking"]) })
        case .targets:
            AnyView(TargetsSettingsView(state: .resolve(
                hosts: [], availability: .unconfigured, confirmed: nil, remembered: nil
            ), send: { _ in intents.record() }, setup: { Text("Synthetic Mac Setup destination") }))
        case .listening:
            AnyView(ListeningSettingsView(state: ListeningSettingsState(controller: nil),
                                          masksDuringReplies: false, send: { _ in intents.record() }))
        case .notifications:
            AnyView(NotificationsSettingsView(status: nil, isChecking: false, send: { _ in intents.record() }))
        }
    }

    @MainActor
    private func audio() -> AnyView {
        let preferred = AudioPort(id: "example-usb", name: "Example USB microphone", kind: .usb)
        let state = AudioRoutesSheetState.resolve(
            diagnostics: .inactive, inputs: [], preferred: preferred, selection: .inactive, hfp: nil)
        return AnyView(AudioSettingsOverviewView(
            state: state, preferredInput: preferred, sessionStatus: "Audio inactive"
        ) { Text("Synthetic Audio session tools destination") })
    }

    @MainActor
    private func privacy(_ intents: NativeSettingsGalleryIntents) -> AnyView {
        // Reuse the existing empty, scripted fixture's immutable projection. No connect/intent method is called.
        let fixture = PrivacySettingsFixture(
            connections: HostConnectionStore(connector: ScriptedConnector()), host: nil)
        return AnyView(PrivacySettingsView(state: fixture.privacySettingsState(now: .distantPast),
                                          send: { _ in intents.record() }))
    }

    @MainActor
    private func advanced(_ intents: NativeSettingsGalleryIntents) -> AnyView {
        AnyView(AdvancedSettingsView(
            diagnosticsEnabled: false, bufferedEvents: 0, collectingHostName: nil,
            buildInfo: StationBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "456"
            ]), send: { _ in intents.record() }, tools: { tools(["Labs", "Turn-taking"]) }
        ))
    }

    @MainActor
    private func tools(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            NavigationLink(name) { Text("Synthetic \(name) destination") }
        }
    }
}
#endif
