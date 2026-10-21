#if os(macOS)
import Foundation
import HailCore
import Security
import SwiftUI

/// Start, Stop, the explicit device choice and the consent steps for one coaching run. Choices are held by device
/// UID, never by the reusable numeric ID. Awareness and consents are cleared when a run ends, so each Start asks
/// again. Consent toggles show `PrivateCoachingConsentText.Shown`, visibly marked as placeholder wording.
struct MacCoachingCard: View {
    let playback: ReplyPlaybackController
    @State private var controller = MacCoachingController.shared
    @State private var exclusion = PrivateListeningExclusion.shared
    @State private var setup: PrivateCoachingSetup?
    @State private var setupError: PrivateCoachingSetup.SetupError?
    @State private var microphones: [MacCoachingDevice] = []
    @State private var outputs: [MacCoachingDevice] = []
    @State private var microphoneKey = ""
    @State private var outputKey = ""
    @State private var provider = PrivateCoachingSetup.Provider.local
    @State private var awareness = false
    @State private var hostedConsent = false
    @State private var hostedSpeechConsent = false
    /// The output last confirmed as headphones, by UID and in memory only, until another device is chosen (#604).
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
                Text(MacCoachingTrustedAppSummary.current())
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("station.coaching-trusted-app")
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
            awareness = false; hostedConsent = false; hostedSpeechConsent = false // Every Start confirms again.
        }
    }

    @ViewBuilder private var choices: some View {
        Picker("Room microphone", selection: $microphoneKey) {
            Text("Choose a microphone").tag("")
            ForEach(microphones) { Text($0.name).tag($0.key) }
        }
        Picker("Private output", selection: $outputKey) {
            Text("Choose headphones").tag("")
            ForEach(outputs) { Text($0.name).tag($0.key) }
        }
        if let output, headphoneCheckNeeded(output) {
            Toggle(PrivateCoachingConsentText.Shown.headphoneCheck, isOn: Binding(
                get: { confirmedKey == output.key }, set: { confirmedKey = $0 ? output.key : nil }))
        }
        if setup?.offersHosted == true {
            Picker("Coaching provider", selection: $provider) {
                Text("Local").tag(PrivateCoachingSetup.Provider.local)
                Text("Hosted").tag(PrivateCoachingSetup.Provider.hosted)
            }
            .pickerStyle(.segmented)
        }
        Toggle(PrivateCoachingConsentText.Shown.participantAwareness, isOn: $awareness)
        if provider == .hosted {
            Toggle(PrivateCoachingConsentText.Shown.hostedProvider, isOn: $hostedConsent)
        }
        if setup?.speechServices == .hosted {
            Toggle(PrivateCoachingConsentText.Shown.hostedSpeech, isOn: $hostedSpeechConsent)
        }
    }

    private var output: MacCoachingDevice? { outputs.first { $0.key == outputKey } }
    private var microphone: MacCoachingDevice? { microphones.first { $0.key == microphoneKey } }

    /// Bluetooth and USB outputs always need the check; it is satisfied only by this exact UID.
    private func headphoneCheckNeeded(_ output: MacCoachingDevice) -> Bool {
        output.transport.needsHeadphoneCheck(outputKey: output.key, lastConfirmedKey: nil)
    }

    private var gate: PrivateCoachingStartGate {
        PrivateCoachingStartGate(
            state: controller.state, setupReady: setup != nil, ambientListening: exclusion.ambientOn,
            captureActive: playback.isCaptureSuppressed,
            microphoneChosen: microphone != nil, outputChosen: output != nil,
            headphoneCheckNeeded: output.map(headphoneCheckNeeded) ?? false,
            headphonesConfirmed: output.map { confirmedKey == $0.key } ?? false,
            awarenessConfirmed: awareness, hostedChosen: provider == .hosted, hostedConsentConfirmed: hostedConsent,
            hostedSpeech: setup?.speechServices == .hosted, hostedSpeechConsentConfirmed: hostedSpeechConsent)
    }

    private var status: String {
        switch controller.state {
        case .idle: "Off. The microphone is closed."
        case .starting: "Starting…"
        case .live: "Coaching. Cues play only in your headphones."
        case .suspendedOnRouteChange: "Stopped because the audio route changed. Start again when ready."
        case .stopped: "Stopped. The microphone is closed."
        case .error: "Coaching could not run. Check the setup, the trusted app and devices, then Start again."
        }
    }

    private func hint(_ blocker: PrivateCoachingStartGate.Blocker?) -> String? {
        switch blocker {
        case nil, .notIdle, .awareness, .hostedConsent, .hostedSpeechConsent, .headphoneCheck: nil
        case .setupMissing: setupError == .untrustedFile
            ? "The coaching setup file or haild is not private to you, so coaching stays off."
            : "Coaching is not set up on this Mac yet (setup file, then `haild coaching trust-app`)."
        case .ambientListening: "Turn off ambient listening to start private coaching."
        case .captureActive: "Finish the other listening first."
        case .noMicrophone: "Choose a room microphone."
        case .noOutput: "Choose headphones. Only outputs macOS reports as headphones are listed."
        }
    }

    private func refresh() {
        feedback = nil
        do { setup = try PrivateCoachingSetup.load(from: Self.setupFile); setupError = nil } catch {
            setup = nil; setupError = error as? PrivateCoachingSetup.SetupError
        }
        if setup?.offersHosted != true { provider = .local }
        microphones = MacCoachingDeviceInventory.roomMicrophones()
        outputs = MacCoachingDeviceInventory.privateOutputs()
        if microphone == nil { microphoneKey = "" }
        if output == nil { outputKey = "" }
    }

    private func start() {
        feedback = nil
        // Fresh IDs for the chosen UIDs: a numeric ID can be reused by another device after a refresh.
        guard gate.blocker == nil, let setup,
              let output = MacCoachingDeviceInventory.privateOutputs().first(where: { $0.key == outputKey }),
              let microphone = MacCoachingDeviceInventory.roomMicrophones().first(where: { $0.key == microphoneKey })
        else {
            feedback = "The devices changed. Choose them again."
            refresh()
            return
        }
        guard let arguments = try? setup.arguments(
            privateOutput: output.id, roomMicrophone: microphone.id, provider: provider,
            hostedConsentConfirmed: hostedConsent, hostedSpeechConsentConfirmed: hostedSpeechConsent) else {
            feedback = "Coaching is not set up for that provider."
            return
        }
        controller.start(executable: setup.haild, arguments: arguments, playback: playback)
    }
}
/// Shows which app haild will accept (#645), so a rewritten pin is noticeable. Display only: haild decides.
enum MacCoachingTrustedAppSummary {
    private struct Pin: Decodable { let identifier: String; let cdhash: String?; let teamID: String? }

    static func current() -> String {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return "Trusted app: unknown" }
        let file = URL(fileURLWithPath: String(cString: home))
            .appending(path: ".config/hail/coaching-trusted-app.json")
        guard let data = try? Data(contentsOf: file), data.count <= 1_024,
              let pin = try? JSONDecoder().decode(Pin.self, from: data) else {
            return "Trusted app: none. Run `haild coaching trust-app` with this app's path."
        }
        let short = pin.teamID.map { "team \($0)" } ?? "cdhash \(String((pin.cdhash ?? "?").prefix(12)))"
        let mine = ownCDHash().map { pin.cdhash?.hasPrefix($0.prefix(40)) == true } ?? false
        let match = pin.teamID != nil ? "" : (mine ? ", this build" : ", not this build: run trust-app again")
        return "Trusted app: \(pin.identifier) (\(short)\(match))"
    }

    private static func ownCDHash() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
