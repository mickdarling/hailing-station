#if os(macOS)
import CoreAudio
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingInputEvidenceTests {
    @Test(arguments: [false, true])
    func startupDuringMetadataCannotSetOrPublishBinding(afterSet: Bool) {
        let original = MacCoachingInputEvidence(deviceID: 10, uid: "authored-room-input", streams: [11])
        var running = false
        var reads = 0
        var sets: [UInt32] = []
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            _ = try MacCoachingAudioOwner.bindInput(original, read: {
                reads += 1
                if reads == (afterSet ? 2 : 1) { running = true }
                return original
            }, operations: .init(running: { running }, setDevice: { sets.append($0) },
                                currentDevice: { 10 }), output: { true })
        }
        #expect(sets == (afterSet ? [10] : []))
    }

    @Test func nestedObservationRetirementVetoesOuterObservation() throws {
        let original = MacCoachingInputEvidence(deviceID: 10, uid: "authored-room-input", streams: [11])
        var hook: (() -> Void)?
        var outputValid = true
        let bound = try MacCoachingAudioOwner.bindInput(original, read: {
            hook?()
            return original
        }, operations: .init(running: { false }, setDevice: { _ in }, currentDevice: { 10 }),
            output: { outputValid })
        hook = {
            hook = nil
            outputValid = false
            #expect(!bound())
            outputValid = true
        }
        #expect(!bound())
        #expect(!bound())
    }

    @Test func fixedRoomInputRequiresObservedReadbackAndRetiresWithoutRebinding() throws {
        for losesOutput in [false, true] {
            let original = MacCoachingInputEvidence(deviceID: 10, uid: "authored-room-input", streams: [11])
            var evidence: MacCoachingInputEvidence? = original
            var current: UInt32? = 10
            var outputValid = true
            var sets: [UInt32] = []
            let bound = try MacCoachingAudioOwner.bindInput(original, read: { evidence }, operations: .init(
                running: { false }, setDevice: { sets.append($0); current = $0 }, currentDevice: { current }
            ), output: { outputValid })
            #expect(bound() && sets == [10])
            if losesOutput { outputValid = false } else {
                evidence = .init(deviceID: 10, uid: "authored-replaced-input", streams: [11])
            }
            #expect(!bound())
            evidence = original
            outputValid = true
            #expect(!bound() && sets == [10])
        }
    }

    @Test func runningInputOrWrongReadbackCannotBind() throws {
        let original = MacCoachingInputEvidence(deviceID: 10, uid: "authored-room-input", streams: [11])
        for running in [false, true] {
            var sets: [UInt32] = []
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                _ = try MacCoachingAudioOwner.bindInput(original, read: { original }, operations: .init(
                    running: { running }, setDevice: { sets.append($0) }, currentDevice: { 20 }
                ), output: { true })
            }
            #expect(sets == (running ? [] : [10]))
        }
    }

    @Test func roomInputRejectsBluetoothHeadsetAndUnknownEvidence() {
        let rig = MacCoachingEvidenceRig()
        rig.transport = kAudioDeviceTransportTypeBuiltIn
        rig.direction = 1
        rig.terminal = kAudioStreamTerminalTypeMicrophone
        let read = { MacCoachingInputEvidence.read(rig.device, reader: rig.reader, inputs: { _ in rig.streams }) }
        #expect(read() != nil)
        rig.transport = kAudioDeviceTransportTypeBluetooth
        #expect(read() == nil)
        rig.transport = kAudioDeviceTransportTypeBuiltIn
        rig.terminal = kAudioStreamTerminalTypeHeadsetMicrophone
        #expect(read() == nil)
        rig.terminal = nil
        #expect(read() == nil)
    }

    @Test func incompleteOrMixedInputEvidenceCannotQualifyRoomCapture() {
        let edits: [(MacCoachingEvidenceRig) -> Void] = [
            { $0.alive = 0 }, { $0.alive = nil }, { $0.kind = kAudioAggregateDeviceClassID },
            { $0.transport = kAudioDeviceTransportTypeAggregate }, { $0.transport = kAudioDeviceTransportTypeVirtual },
            { $0.transport = kAudioDeviceTransportTypeBluetoothLE }, { $0.transport = nil },
            { $0.uid = "" }, { $0.uid = nil }, { $0.streams = [] }, { $0.streams = nil },
            { $0.streams = [0] }, { $0.streams = [21, 21] }, { $0.streams = Array(21...53) },
            { $0.direction = 0 }, { $0.direction = nil },
            { $0.streams = [21, 22]; $0.terminals[22] = kAudioStreamTerminalTypeReceiverMicrophone }
        ]
        for edit in edits {
            let rig = MacCoachingEvidenceRig()
            rig.transport = kAudioDeviceTransportTypeBuiltIn
            rig.direction = 1
            rig.terminal = kAudioStreamTerminalTypeMicrophone
            edit(rig)
            #expect(MacCoachingInputEvidence.read(rig.device, reader: rig.reader,
                                                inputs: { _ in rig.streams }) == nil)
        }
    }
}
#endif
