import Testing
@testable import HailCore

/// The audio routes sheet's promises over every combination of its inputs (#1115).
@Suite("Audio routes sheet sweep (#1115)")
struct AudioRoutesSheetSweepTests {
    private static let builtIn = AudioPort(id: "built-in", name: "iPhone Microphone", kind: .builtIn)
    private static let usb = AudioPort(id: "usb", name: "USB Microphone", kind: .usb)
    private static let airPods = AudioPort(id: "airpods", name: "AirPods", kind: .bluetoothHFP)
    private static let resolutions: [AudioInputSelectionResolution] = [
        .inactive, .automatic, .confirmed, .fallback, .failed
    ]
    private static let activeInputs: [AudioPort?] = [nil, builtIn, usb, airPods]
    private static let inputLists: [[AudioPort]] = [[], [builtIn], [builtIn, usb], [builtIn, usb, airPods]]
    private static let hfps: [HFPOption?] = [
        nil, HFPOption(isOn: false, failure: nil), HFPOption(isOn: true, failure: "busy")
    ]

    // 2 active × 4 inputs × 4 lists × 4 preferred × 5 resolutions × 2 failures × 3 headset options.
    @Test func everyCombinationKeepsTheSheetsPromises() {
        var count = 0
        for active in [false, true] {
            for input in Self.activeInputs {
                for list in Self.inputLists {
                    for preferred in Self.activeInputs {
                        for resolution in Self.resolutions {
                            for failure in [nil, "route refused"] {
                                for hfp in Self.hfps {
                                    count += 1
                                    let state = AudioRoutesSheetState.resolve(
                                        diagnostics: AudioSessionDiagnostics(
                                            isActive: active, input: input, outputs: [], sampleRate: 0),
                                        inputs: list, preferred: preferred,
                                        selection: AudioInputSelectionState(
                                            resolution: resolution, preferred: preferred, attempted: preferred,
                                            active: input, failureDescription: failure),
                                        hfp: hfp)
                                    check(state, active: active, input: input, list: list)
                                    checkOwnership(state, resolution: resolution, hfp: hfp)
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(count == 3_840)
    }

    private func check(_ state: AudioRoutesSheetState, active: Bool, input: AudioPort?, list: [AudioPort]) {
        let item = "active \(active) input \(String(describing: input?.id)) list \(list.map(\.id))"
        // Jarvis, PR 6 plan: inactive audio names no input in the Active row.
        if !active {
            #expect(state.activeInput == "Audio inactive", "\(item)")
            for port in [Self.builtIn, Self.usb, Self.airPods] {
                #expect(!state.activeInput.contains(port.name), "\(item)")
            }
            #expect(!state.choicesEnabled, "\(item)")
        } else {
            #expect(state.activeInput == (input?.name ?? "No microphone active"), "\(item)")
        }
        // The preferred microphone is never shown as the active one.
        if let preferred = state.preferred { #expect(!preferred.hasPrefix(state.activeInput + " ·"), "\(item)") }
        if !state.choicesEnabled { #expect(state.disabledReason != nil, "\(item)") }
        #expect(state.choices.count == list.count + 1, "\(item)")
        #expect(state.choices.filter(\.isPreferred).count == 1 || state.choices.allSatisfy { !$0.isPreferred },
                "\(item)")
    }

    private func checkOwnership(_ state: AudioRoutesSheetState, resolution: AudioInputSelectionResolution,
                                hfp: HFPOption?) {
        let item = "\(resolution) \(String(describing: hfp))"
        #expect((state.failure != nil) == (resolution == .failed), "\(item)")
        #expect(state.showsRetry == (resolution == .failed), "\(item)")
        #expect((state.hfp == nil) == (hfp == nil), "\(item)")
        // No route is ever called private: a route name isn't private-coaching evidence.
        let text = [state.activeInput, state.preferred, state.status, state.failure, state.output,
                    state.hfpCaption].compactMap { $0 }
        #expect(!text.contains { $0.localizedCaseInsensitiveContains("private") }, "\(item)")
        // The only intents are selections; nothing activates or deactivates audio.
        for choice in state.choices {
            guard case .selectInput = choice.intent else { Issue.record("not a selection: \(item)"); continue }
        }
    }
}
