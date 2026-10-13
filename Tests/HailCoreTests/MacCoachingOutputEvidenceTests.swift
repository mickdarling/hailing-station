#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import HailCore

@MainActor final class MacCoachingEvidenceRig {
    let device: UInt32 = 20
    var alive: UInt32? = 1
    var kind: UInt32? = kAudioDeviceClassID
    var transport: UInt32? = kAudioDeviceTransportTypeBluetooth
    var uid: String? = "authored-private-device"
    var streams: [UInt32]? = [21]
    var terminal: UInt32? = kAudioStreamTerminalTypeHeadphones
    var terminals: [UInt32: UInt32] = [:]
    var direction: UInt32? = 0
    var bound: UInt32? = 20
    var running = false
    var sets: [UInt32] = []
    var afterRead: (() -> Void)?
    var reader: MacCoachingDeviceReader {
        .init(scalar: { [self] object, selector in
            switch selector {
            case kAudioDevicePropertyDeviceIsAlive: alive
            case kAudioObjectPropertyClass: kind
            case kAudioDevicePropertyTransportType: transport
            case kAudioStreamPropertyTerminalType: terminals[object] ?? terminal
            case kAudioStreamPropertyDirection: direction
            default: nil
            }
        }, uid: { [self] _ in uid }, outputs: { [self] _ in streams })
    }
    func evidence() -> MacCoachingDeviceEvidence? {
        let value = MacCoachingDeviceEvidence.read(device, using: reader)
        afterRead?()
        return value
    }
    func bind() throws -> MacCoachingOutputBinding {
        try MacCoachingOutputBinding(deviceID: device, read: { self.evidence() }, operations: .init(
            running: { self.running }, setDevice: { self.sets.append($0); self.bound = $0 },
            currentDevice: { self.bound }
        ))
    }
}

@Suite @MainActor struct MacCoachingOutputEvidenceTests {
    @Test func everyOutputStreamMustBeHeadphones() {
        let rig = MacCoachingEvidenceRig()
        rig.streams = [21, 22]
        #expect(rig.evidence() != nil)
        rig.terminals[22] = kAudioStreamTerminalTypeSpeaker
        #expect(rig.evidence() == nil)
    }

    @Test func bluetoothTransportRequiresActualHeadphoneTerminalAndNeverNames() {
        let rig = MacCoachingEvidenceRig()
        #expect(rig.evidence() != nil)
        for terminal in [kAudioStreamTerminalTypeUnknown, kAudioStreamTerminalTypeSpeaker,
                         kAudioStreamTerminalTypeLine, kAudioStreamTerminalTypeHeadsetMicrophone] {
            rig.terminal = terminal
            #expect(rig.evidence() == nil)
        }
        rig.terminal = nil
        #expect(rig.evidence() == nil)
    }

    @Test func incompleteDeadAggregateVirtualAndAmbiguousDevicesFailClosed() {
        let edits: [(MacCoachingEvidenceRig) -> Void] = [
            { $0.alive = 0 }, { $0.alive = nil }, { $0.kind = kAudioAggregateDeviceClassID },
            { $0.kind = nil }, { $0.transport = kAudioDeviceTransportTypeAggregate },
            { $0.transport = kAudioDeviceTransportTypeVirtual }, { $0.transport = nil },
            { $0.uid = "" }, { $0.uid = nil }, { $0.streams = [] }, { $0.streams = nil },
            { $0.streams = [0] }, { $0.streams = [21, 21] }, { $0.streams = Array(21...53) },
            { $0.direction = 1 }, { $0.direction = nil }
        ]
        for edit in edits {
            let rig = MacCoachingEvidenceRig()
            edit(rig)
            #expect(rig.evidence() == nil)
        }
    }

    @Test func bindingRequiresUnstartedExclusiveOwnerAndActualReadback() throws {
        let rig = MacCoachingEvidenceRig()
        rig.running = true
        #expect(throws: CoachingSafetyError.unsafeOutput) { try rig.bind() }
        #expect(rig.sets.isEmpty)
        rig.running = false
        let binding = try rig.bind()
        #expect(binding.isStillBound() && rig.sets == [20])
        rig.bound = 30
        #expect(!binding.isStillBound())
        rig.bound = 20
        #expect(!binding.isStillBound() && rig.sets == [20])
    }

    @Test func replacedUIDOrObservedBindingChangeCannotRevive() throws {
        for changeUID in [false, true] {
            let rig = MacCoachingEvidenceRig()
            let binding = try rig.bind()
            if changeUID { rig.uid = "another-authored-device" } else {
                rig.afterRead = { rig.bound = 30 }
            }
            #expect(!binding.isStillBound())
            rig.uid = "authored-private-device"
            rig.afterRead = nil
            rig.bound = 20
            #expect(!binding.isStillBound())
        }
    }

    @Test func explicitRetirementNeverRebinds() throws {
        let rig = MacCoachingEvidenceRig()
        let binding = try rig.bind()
        binding.retire()
        #expect(!binding.isStillBound() && rig.sets == [20])
    }
}
#endif
