#if os(macOS)
import CoreAudio
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingUSBInputEvidenceTests {
    @Test func standardUSBMicrophoneQualifiesWithoutChangingOutputClassification() {
        let rig = microphone()
        #expect(read(rig) != nil)
        rig.direction = 0
        #expect(read(rig) == nil)
        #expect(rig.evidence() == nil)
        rig.terminal = 0x0302 // USB headphones do not change the private-output policy.
        #expect(rig.evidence() == nil)
    }

    @Test(arguments: [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
                      kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAggregate,
                      kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypePCI, UInt32(0)])
    func numericMicrophoneCodeCannotQualifyOtherTransports(transport: UInt32) {
        let rig = microphone()
        rig.transport = transport
        #expect(read(rig) == nil)
    }

    @Test(arguments: [UInt32(0), 0x0200, 0x0202, 0x0203, 0x0204, 0x0205, 0x0206,
                      0x0301, 0x0302, 0x0402, kAudioStreamTerminalTypeHeadsetMicrophone,
                      kAudioStreamTerminalTypeReceiverMicrophone, kAudioStreamTerminalTypeLine])
    func USBDoesNotGrantUnknownOtherMicrophonesOrOutputs(terminal: UInt32) {
        let rig = microphone()
        rig.terminal = terminal
        #expect(read(rig) == nil)
    }

    @Test func everyInputStreamStillRequiresGenericMicrophoneEvidence() {
        let rig = microphone()
        rig.streams = [21, 22]
        #expect(read(rig) != nil)
        rig.terminals[22] = kAudioStreamTerminalTypeMicrophone
        #expect(read(rig) != nil)
        rig.terminals[22] = 0x0203
        #expect(read(rig) == nil)
        rig.terminals = [:]
        rig.terminal = nil
        #expect(read(rig) == nil)
    }

    @Test func USBMicrophoneRetainsAllDeviceAndStreamGuards() {
        let edits: [(MacCoachingEvidenceRig) -> Void] = [
            { $0.alive = 0 }, { $0.alive = nil }, { $0.kind = kAudioAggregateDeviceClassID },
            { $0.kind = nil }, { $0.transport = nil }, { $0.uid = "" }, { $0.uid = nil },
            { $0.streams = [] }, { $0.streams = nil }, { $0.streams = [0] },
            { $0.streams = [21, 21] }, { $0.streams = Array(21...53) },
            { $0.direction = 0 }, { $0.direction = nil }, { $0.terminal = nil }
        ]
        for edit in edits {
            let rig = microphone()
            edit(rig)
            #expect(read(rig) == nil)
        }
    }

    @Test func changedUSBMicrophoneEvidenceRetiresBindingWithoutRebinding() throws {
        let rig = microphone()
        let original = try #require(read(rig))
        let bound = try MacCoachingAudioOwner.bindInput(original, read: { read(rig) }, operations: .init(
            running: { false }, setDevice: { rig.sets.append($0) }, currentDevice: { rig.device }
        ), output: { true })
        #expect(bound())
        rig.terminal = 0x0203
        #expect(!bound())
        rig.terminal = 0x0201
        #expect(!bound() && rig.sets == [rig.device])
    }

    private func microphone() -> MacCoachingEvidenceRig {
        let rig = MacCoachingEvidenceRig()
        rig.transport = kAudioDeviceTransportTypeUSB
        rig.direction = 1
        rig.terminal = 0x0201
        return rig
    }

    private func read(_ rig: MacCoachingEvidenceRig) -> MacCoachingInputEvidence? {
        MacCoachingInputEvidence.read(rig.device, reader: rig.reader, inputs: { _ in rig.streams })
    }
}
#endif
