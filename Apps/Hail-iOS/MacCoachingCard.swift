#if os(macOS)
import Foundation
import HailCore
import SwiftUI

/// The Mac's private coaching slot (#645). Opt-in: nothing shows until `coaching.mac.enabled` is set, for example
/// with `defaults write <bundle-id> coaching.mac.enabled -bool YES`.
struct MacCoachingSlot: View {
    let playback: ReplyPlaybackController
    let ambientListening: Bool
    @AppStorage("coaching.mac.enabled") private var enabled = false

    var body: some View {
        if enabled { MacCoachingCard(playback: playback, ambientListening: ambientListening) }
    }
}

/// Start, Stop, the explicit device choice and the consent steps for one coaching run. Every confirmation is
/// cleared when a run ends, so each Start asks again. Placeholder wording: see `PrivateCoachingConsentText`.
struct MacCoachingCard: View {
    let playback: ReplyPlaybackController
    let ambientListening: Bool
    @State private var controller = MacCoachingController.shared
    @State private var setup: PrivateCoachingSetup?
    @State private var microphones: [MacCoachingDevice] = []
    @State private var outputs: [MacCoachingDevice] = []
    @State private var microphoneID: UInt32 = 0
    @State private var outputID: UInt32 = 0
    @State private var provider = PrivateCoachingSetup.Provider.local
    @State private var awareness = false
    @State private var hostedConsent = false
    @State private var headphonesConfirmed = false
    /// The device last confirmed as headphones, kept only in memory until another device is chosen (#604).
    @State private var confirmedKey: String?
    @State private var feedback: String?

    static let setupFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Hailing Station/coaching-setup.json")

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(status).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("station.coaching-status")
                choices.disabled(!controller.state.canStart)
                HStack {
                    Button("Start", systemImage: "ear") { start() }
                        .disabled(gate.blocker != nil)
                        .accessibilityIdentifier("station.coaching-start")
                    Button("Stop", systemImage: "stop.fill") { controller.stop() }
                        .disabled(!controller.state.holdsAudio)
                        .accessibilityIdentifier("station.coaching-stop")
                    Button("Refresh devices") { refresh() }
                        .disabled(!controller.state.canStart)
                }
                .buttonStyle(.bordered)
                if let hint = feedback ?? hint(gate.blocker) {
                    Text(hint).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Private coaching", systemImage: "ear.badge.waveform").font(.headline)
        }
        .accessibilityIdentifier("station.coaching")
        .task { refresh() }
        .onChange(of: controller.state) { _, state in
            guard state.canStart else { return }
            awareness = false; hostedConsent = false // Every Start confirms again.
        }
    }

    @ViewBuilder private var choices: some View {
        Picker("Room microphone", selection: $microphoneID) {
            Text("Choose a microphone").tag(UInt32(0))
            ForEach(microphones) { Text($0.name).tag($0.id) }
        }
        Picker("Private output", selection: $outputID) {
            Text("Choose headphones").tag(UInt32(0))
            ForEach(outputs) { Text($0.name).tag($0.id) }
        }
        .onChange(of: outputID) { _, _ in headphonesConfirmed = false }
        if headphoneCheckNeeded {
            Toggle(PrivateCoachingConsentText.headphoneCheck, isOn: $headphonesConfirmed)
        }
        if setup?.offersHosted == true {
            Picker("Coaching provider", selection: $provider) {
                Text("Local").tag(PrivateCoachingSetup.Provider.local)
                Text("Hosted").tag(PrivateCoachingSetup.Provider.hosted)
            }
            .pickerStyle(.segmented)
        }
        Toggle(PrivateCoachingConsentText.participantAwareness, isOn: $awareness)
        if provider == .hosted {
            Toggle(PrivateCoachingConsentText.hostedProvider, isOn: $hostedConsent)
        }
    }

    private var output: MacCoachingDevice? { outputs.first { $0.id == outputID } }

    private var headphoneCheckNeeded: Bool {
        guard let output else { return false }
        return output.transport.needsHeadphoneCheck(outputKey: output.key, lastConfirmedKey: confirmedKey)
    }

    private var gate: PrivateCoachingStartGate {
        PrivateCoachingStartGate(
            state: controller.state, setupReady: setup != nil, ambientListening: ambientListening,
            captureActive: playback.isCaptureSuppressed,
            microphoneChosen: microphones.contains { $0.id == microphoneID }, outputChosen: output != nil,
            headphoneCheckNeeded: headphoneCheckNeeded, headphonesConfirmed: headphonesConfirmed,
            awarenessConfirmed: awareness, hostedChosen: provider == .hosted, hostedConsentConfirmed: hostedConsent)
    }

    private var status: String {
        switch controller.state {
        case .idle: "Off. The microphone is closed."
        case .starting: "Starting…"
        case .live: "Coaching. Cues play only in your headphones."
        case .suspendedOnRouteChange: "Stopped because the audio route changed. Start again when ready."
        case .stopped: "Stopped. The microphone is closed."
        case .error: "Coaching could not run. Check the setup and devices, then Start again."
        }
    }

    private func hint(_ blocker: PrivateCoachingStartGate.Blocker?) -> String? {
        switch blocker {
        case nil, .notIdle, .awareness, .hostedConsent, .headphoneCheck: nil
        case .setupMissing: "Coaching is not set up on this Mac yet."
        case .ambientListening: "Turn off ambient listening to start private coaching."
        case .captureActive: "Finish the other listening first."
        case .noMicrophone: "Choose a room microphone."
        case .noOutput: "Choose headphones. Only outputs macOS reports as headphones are listed."
        }
    }

    private func refresh() {
        feedback = nil
        setup = (try? Data(contentsOf: Self.setupFile)).flatMap { try? PrivateCoachingSetup.parse($0) }
        if setup?.offersHosted != true { provider = .local }
        microphones = MacCoachingDeviceInventory.roomMicrophones()
        outputs = MacCoachingDeviceInventory.privateOutputs()
        if !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = 0 }
        if !outputs.contains(where: { $0.id == outputID }) { outputID = 0 }
    }

    private func start() {
        feedback = nil
        guard gate.blocker == nil, let setup, let output,
              let microphone = microphones.first(where: { $0.id == microphoneID }),
              // A device ID can be reused by another device; the UID key catches that before Start.
              MacCoachingDeviceInventory.privateOutputs().contains(output),
              MacCoachingDeviceInventory.roomMicrophones().contains(microphone) else {
            feedback = "The devices changed. Choose them again."
            refresh()
            return
        }
        guard let arguments = try? setup.arguments(privateOutput: output.id, roomMicrophone: microphone.id,
                                                   provider: provider, hostedConsentConfirmed: hostedConsent) else {
            feedback = "Coaching is not set up for that provider."
            return
        }
        if headphoneCheckNeeded { confirmedKey = output.key }
        controller.start(executable: setup.haild, arguments: arguments, playback: playback)
    }
}
#endif
