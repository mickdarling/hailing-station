#if os(macOS)
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeAudioSettingsOverviewTests {
    private static let builtIn = AudioPort(id: "built-in", name: "Built-in microphone", kind: .builtIn)
    private static let usb = AudioPort(id: "usb", name: "Example USB microphone", kind: .usb)
    private static let speaker = AudioPort(id: "speaker", name: "Example speaker", kind: .other)

    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func inactiveOverviewDoesNotPresentStaleRoutesOrTouchTheOwner(typeSize: DynamicTypeSize) async {
        let owner = AudioSettingsOwnerSpy(AudioSettingsTestSnapshot(
            diagnostics: AudioSessionDiagnostics(
                isActive: false, input: Self.builtIn, outputs: [Self.speaker], sampleRate: 48_000),
            inputs: [Self.usb], preferred: Self.usb, selection: .inactive))
        let model = AudioRouteModel(controller: owner)
        await model.refresh() // The root's existing observation supplies state, never the new view.
        await owner.clearCalls()
        let host = NativeAudioSettingsHost(model: model, typeSize: typeSize)
        defer { host.finish() }
        await host.render()
        #expect(host.rowText("input").contains("Audio inactive"))
        #expect(!host.rowText("input").contains(Self.builtIn.name))
        #expect(host.rowText("preferred").contains("Example USB microphone · not active"))
        #expect(host.rowText("output").contains("System output"))
        #expect(!host.rowText("output").contains(Self.speaker.name))
        #expect(await owner.calls.isEmpty, "Mounting must not query, subscribe or mutate the audio controller")
        host.hide()
        await host.render()
        #expect(await owner.calls.isEmpty, "Leaving must not clean up the audio owner's session")
    }

    @Test func ownerUpdatesClearFailureWithoutForgettingTheConfirmedPreference() async {
        let failed = snapshot(input: Self.builtIn, resolution: .failed, reason: "Route not confirmed")
        let owner = AudioSettingsOwnerSpy(failed)
        let model = AudioRouteModel(controller: owner)
        await model.refresh()
        await owner.clearCalls()
        let host = NativeAudioSettingsHost(model: model)
        defer { host.finish() }
        await host.render()
        #expect(host.rowText("failure").contains(
            "Could not apply Example USB microphone: Route not confirmed."))
        #expect(host.rowText("input").contains(Self.builtIn.name))
        #expect(host.rowText("preferred").contains("unavailable"))
        #expect(await owner.calls.isEmpty)

        await owner.set(snapshot(input: Self.usb, resolution: .confirmed))
        await model.refresh() // Simulates the scene's next observation of the SAME model.
        #expect(await owner.calls == ["diagnostics", "inputs", "preferred", "selection"])
        await owner.clearCalls()
        await host.render()
        #expect(host.rowText("failure").isEmpty)
        #expect(host.rowText("input").contains(Self.usb.name))
        #expect(host.rowText("preferred").contains(Self.usb.name), "A matching saved choice remains visible")
        #expect(!host.rowText("preferred").contains("unavailable"))
        #expect(!host.rowText("preferred").contains("not active"))
        host.hide()
        await host.render()
        #expect(await owner.calls.isEmpty)
    }

    @Test func anActiveSessionWithoutReportedRoutesDoesNotInventThem() async {
        let owner = AudioSettingsOwnerSpy(AudioSettingsTestSnapshot(
            diagnostics: AudioSessionDiagnostics(isActive: true, input: nil, outputs: [], sampleRate: 0),
            inputs: [], preferred: nil,
            selection: AudioInputSelectionState(
                resolution: .automatic, preferred: nil, attempted: nil, active: nil)))
        let model = AudioRouteModel(controller: owner)
        await model.refresh()
        await owner.clearCalls()
        let host = NativeAudioSettingsHost(model: model)
        defer { host.finish() }
        await host.render()
        #expect(host.rowText("input").contains("No microphone active"))
        #expect(host.rowText("preferred").contains("Automatic · no preference reported"))
        #expect(host.rowText("output").contains("System output"))
        #expect(await owner.calls.isEmpty)
    }

    private func snapshot(input: AudioPort, resolution: AudioInputSelectionResolution, reason: String? = nil)
        -> AudioSettingsTestSnapshot {
        AudioSettingsTestSnapshot(
            diagnostics: AudioSessionDiagnostics(
                isActive: true, input: input, outputs: [Self.speaker], sampleRate: 48_000),
            inputs: [input], preferred: Self.usb,
            selection: AudioInputSelectionState(
                resolution: resolution, preferred: Self.usb, attempted: Self.usb,
                active: input, failureDescription: reason))
    }
}
#endif
