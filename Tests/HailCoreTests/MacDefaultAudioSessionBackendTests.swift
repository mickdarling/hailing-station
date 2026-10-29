#if os(macOS)
import CoreAudio
import Testing
@testable import HailCore

@Suite("Mac default route adapter")
@MainActor
struct MacDefaultAudioSessionBackendTests {
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

    @Test func transientReadFailureKeepsLastInputButSuccessfulRemovalClearsIt() async throws {
        let microphone = AudioPort(id: "authored.input", name: "Authored microphone", kind: .usb)
        var reading: AudioSessionDiagnostics? = AudioSessionDiagnostics(
            isActive: false, input: microphone, outputs: [], sampleRate: 48_000
        )
        let output = AudioPort(id: "authored.output", name: "Authored output", kind: .usb)
        var outputs: [AudioPort] = []
        let backend = MacDefaultAudioSessionBackend(readRouteResult: { active in
            (AudioSessionDiagnostics(isActive: active, input: reading?.input,
                outputs: outputs, sampleRate: reading?.sampleRate ?? 0), reading == nil)
        })
        #expect(await backend.availableInputs() == [microphone])
        reading = nil // Failed HAL read, rather than a successful no-device response.
        outputs = [output]
        let cached = await backend.diagnostics(isActive: true)
        #expect(cached.input == microphone && cached.sampleRate == 48_000 && cached.isActive)
        #expect(cached.outputs == [output]) // Input churn must not cache a stale output route.
        #expect(await backend.availableInputs() == [microphone])
        try await backend.selectInput(id: microphone.id)
        reading = .inactive // Successful read confirms actual device removal.
        outputs = []
        #expect(await backend.availableInputs().isEmpty)
        reading = nil
        #expect(await backend.diagnostics(isActive: false) == .inactive)
    }

    @Test func initialReadFailureDoesNotInventInput() async {
        let backend = MacDefaultAudioSessionBackend(readRouteResult: { _ in (.inactive, true) })
        #expect(await backend.availableInputs().isEmpty)
        #expect(await backend.diagnostics(isActive: false) == .inactive)
    }

    @Test func missingMetadataDoesNotInventAMicrophone() async {
        let backend = MacDefaultAudioSessionBackend(readRoute: { _ in .inactive })
        #expect(await backend.availableInputs().isEmpty)
        await #expect(throws: AudioInputSelectionError.self) { try await backend.selectInput(id: "absent") }
    }
}
#endif
