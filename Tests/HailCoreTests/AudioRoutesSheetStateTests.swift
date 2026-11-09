import Testing
@testable import HailCore

@Suite("Audio routes sheet (#1115)")
struct AudioRoutesSheetStateTests {
    private static let builtIn = AudioPort(id: "built-in", name: "iPhone Microphone", kind: .builtIn)
    private static let usb = AudioPort(id: "usb", name: "USB Microphone", kind: .usb)
    private static let airPods = AudioPort(id: "airpods", name: "AirPods", kind: .bluetoothHFP)

    private func resolve(
        active: Bool = true, input: AudioPort? = builtIn, inputs: [AudioPort] = [builtIn, usb],
        preferred: AudioPort? = nil, resolution: AudioInputSelectionResolution = .automatic,
        failure: String? = nil, hfp: HFPOption? = nil
    ) -> AudioRoutesSheetState {
        AudioRoutesSheetState.resolve(
            diagnostics: AudioSessionDiagnostics(
                isActive: active, input: input, outputs: [AudioPort(id: "spk", name: "Speaker", kind: .other)],
                sampleRate: 48_000),
            inputs: inputs, preferred: preferred,
            selection: AudioInputSelectionState(
                resolution: resolution, preferred: preferred, attempted: preferred, active: input,
                failureDescription: failure),
            hfp: hfp)
    }

    @Test func activeAudioNamesTheMicrophoneAndOutputApart() {
        let state = resolve()
        #expect(state.activeInput == "iPhone Microphone")
        #expect(state.status == "Using iPhone Microphone automatically")
        #expect(state.output == "Speaker")
        #expect(state.choicesEnabled)
        #expect(state.disabledReason == nil)
        #expect(state.choices.map(\.name) == ["Automatic", "iPhone Microphone", "USB Microphone"])
        #expect(state.choices.first?.isPreferred == true)
    }

    // Jarvis, PR 6 plan: inactive audio never shows a last-known or preferred input as current.
    @Test func inactiveAudioNamesNoInput() {
        let state = resolve(active: false, input: Self.builtIn, preferred: Self.usb, resolution: .confirmed)
        #expect(state.activeInput == "Audio inactive")
        #expect(state.status == "Audio inactive")
        #expect(state.output == "System output")
        #expect(!state.choicesEnabled)
        #expect(state.disabledReason == "Choose a microphone while audio is active.")
        #expect(state.preferred == "USB Microphone · not active")
    }

    @Test func aPreferredMicrophoneThatIsntActiveIsMarked() {
        let state = resolve(preferred: Self.airPods, resolution: .fallback)
        #expect(state.preferred == "AirPods · unavailable")
        #expect(state.status == "Using iPhone Microphone; preferred AirPods unavailable")
        #expect(state.choices.allSatisfy { !$0.isPreferred })
        #expect(resolve(preferred: Self.usb, resolution: .fallback).preferred == "USB Microphone · not active")
        #expect(resolve(input: Self.usb, preferred: Self.usb, resolution: .confirmed).preferred == nil)
    }

    // Jarvis, PR 6 plan: a failure stays visible, with Retry, until the owner observes success.
    @Test func aFailureStaysUntilTheOwnerReportsSuccess() {
        let failed = resolve(preferred: Self.usb, resolution: .failed, failure: "The route was not confirmed")
        #expect(failed.failure == "Could not apply USB Microphone: The route was not confirmed.")
        #expect(failed.showsRetry)
        #expect(failed.status == "Microphone needs attention")
        #expect(failed.microphoneAccessibilityLabel.contains(failed.failure ?? "missing"))
        let again = resolve(preferred: Self.usb, resolution: .failed, failure: "The route was not confirmed")
        #expect(again.failure == failed.failure)
        let confirmed = resolve(input: Self.usb, preferred: Self.usb, resolution: .confirmed)
        #expect(confirmed.failure == nil)
        #expect(!confirmed.showsRetry)
    }

    @Test func noMicrophonesGivesItsOwnReason() {
        let state = resolve(input: nil, inputs: [])
        #expect(state.activeInput == "No microphone active")
        #expect(state.disabledReason == "No microphones are available.")
        #expect(state.choices.map(\.name) == ["Automatic"])
    }

    // Jarvis, PR 6 plan: the apply failure persists across a re-resolve with the same inputs.
    @Test func theHeadsetRowShowsOnlyWithTheCapabilityAndKeepsItsFailure() {
        #expect(resolve().hfp == nil)
        #expect(resolve().hfpCaption == nil)
        let off = resolve(hfp: HFPOption(isOn: false, failure: nil))
        #expect(off.hfpCaption == AudioRoutesSheetState.hfpDetail)
        #expect(off.hfpCaption?.contains("can interrupt") == true)
        let failing = HFPOption(isOn: true, failure: "Applies when audio next starts: busy")
        #expect(resolve(hfp: failing).hfpCaption == "Applies when audio next starts: busy")
        #expect(resolve(hfp: failing).hfpCaption == resolve(hfp: failing).hfpCaption)
    }

    @Test func choicesAskOnlyToSelect() {
        let state = resolve()
        #expect(state.choices.map(\.intent) == [.selectInput(nil), .selectInput("built-in"), .selectInput("usb")])
    }
}
