#if os(macOS)
import CoreAudio
import Testing
@testable import HailCore

@Suite("Mac default route adapter")
@MainActor
struct MacDefaultAudioSessionBackendTests {
    @Test func reusedDeviceNumberDoesNotPreserveAChoiceOfAnotherDevice() {
        let original = MacCoachingDevice(id: 7, name: "Authored input", uid: "authored.original")
        let replacement = MacCoachingDevice(id: 7, name: "Authored input", uid: "authored.replacement")
        #expect(original != replacement)
        #expect(![replacement].contains(original))
    }

    @Test func metadataCannotClaimBluetoothHandsFreeOrUnknownWired() {
        for transport in [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                          kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual,
                          kAudioDeviceTransportTypeAirPlay, UInt32(0)] {
            #expect(MacDefaultAudioSessionBackend.kind(for: transport) == .other)
        }
        #expect(MacDefaultAudioSessionBackend.kind(for: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(MacDefaultAudioSessionBackend.kind(for: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    }

    @Test func onlyCurrentDefaultIsAcceptedWithoutChangingHardware() async throws {
        let first = AudioPort(id: "authored.first", name: "Authored microphone", kind: .usb)
        let second = AudioPort(id: "authored.second", name: "Replacement microphone", kind: .builtIn)
        var current = first
        let backend = MacDefaultAudioSessionBackend(readRoute: { active in
            AudioSessionDiagnostics(isActive: active, input: current, outputs: [], sampleRate: 48_000)
        })
        #expect(await backend.availableInputs() == [first])
        try await backend.selectInput(id: first.id)
        #expect(await backend.diagnostics(isActive: true).isActive)
        current = second
        await #expect(throws: AudioInputSelectionError.self) { try await backend.selectInput(id: first.id) }
        try await backend.selectInput(id: nil)
        #expect(await backend.availableInputs() == [second])
        #expect(current == second)
    }

    @Test func missingMetadataDoesNotInventAMicrophone() async {
        let backend = MacDefaultAudioSessionBackend(readRoute: { _ in .inactive })
        #expect(await backend.availableInputs().isEmpty)
        await #expect(throws: AudioInputSelectionError.self) { try await backend.selectInput(id: "absent") }
    }
}
#endif
