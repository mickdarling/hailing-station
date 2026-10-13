#if os(macOS)
import AudioToolbox
import AVFAudio
import Foundation

@MainActor
struct MacCoachingBindingOperations {
    var running: () -> Bool
    var setDevice: (UInt32) throws -> Void
    var currentDevice: () -> UInt32?

    static func live(engine: AVAudioEngine) throws -> Self {
        guard let unit = engine.outputNode.audioUnit else { throw CoachingSafetyError.unsafeOutput }
        let component = AudioComponentInstanceGetComponent(unit)
        var description = AudioComponentDescription()
        guard AudioComponentGetDescription(component, &description) == noErr,
              description.componentType == kAudioUnitType_Output,
              description.componentSubType == kAudioUnitSubType_HALOutput else {
            throw CoachingSafetyError.unsafeOutput // Never use a system/default-output unit that follows fallback.
        }
        return Self(running: { engine.isRunning }, setDevice: { device in
            var value = device
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &value, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
                throw CoachingSafetyError.unsafeOutput
            }
        }, currentDevice: {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &value, &size) == noErr, size == MemoryLayout<UInt32>.size else { return nil }
            return value
        })
    }
}

/// Fixed, exclusive owner binding prerequisite; not a coaching qualification or completed renderer/lifetime.
/// Caller owns an unstarted output-only engine. No default-device writes, engine start, capture or playback here.
@MainActor
final class MacCoachingOutputBinding {
    private let original: MacCoachingDeviceEvidence
    private let read: () -> MacCoachingDeviceEvidence?
    private let operations: MacCoachingBindingOperations
    private var retired = false

    init(deviceID: UInt32, read: @escaping () -> MacCoachingDeviceEvidence?,
         operations: MacCoachingBindingOperations) throws {
        guard !operations.running(), let evidence = read(), evidence.deviceID == deviceID,
              !operations.running() else {
            throw CoachingSafetyError.unsafeOutput
        }
        original = evidence
        self.read = read
        self.operations = operations
        try operations.setDevice(deviceID)
        guard !operations.running(), isStillBound(), !operations.running(), !retired else {
            throw CoachingSafetyError.unsafeOutput
        }
    }

    /// Rechecks the *observed* unit device and all output terminal metadata; never rebinds or revives on failure.
    func isStillBound() -> Bool {
        guard !retired, operations.currentDevice() == original.deviceID, read() == original,
              operations.currentDevice() == original.deviceID, !retired else { retired = true; return false }
        return true
    }

    func retire() { retired = true }
}
#endif
