#if os(macOS)
import AudioToolbox
import AVFAudio
public import Observation

/// Failed native disposal retains the callback capability until process exit; no automatic restart/retry.
@MainActor @Observable public final class MacCoachingInputCleanup {
    public static let shared = MacCoachingInputCleanup()
    public private(set) var requiresAppRestart = false
    @ObservationIgnored private var retained: [HeldInput] = []
    var retainedCount: Int { retained.count }
    init() {}
    func hold(_ unit: AudioUnit, driver: MacCoachingHALInputDriver, context: MacCoachingHALInputDelivery?) {
        retained.append(HeldInput(unit: unit, driver: driver, context: context))
        requiresAppRestart = true
    }
    private struct HeldInput {
        let unit: AudioUnit
        let driver: MacCoachingHALInputDriver
        let context: MacCoachingHALInputDelivery?
    }
}

/// The native boundary is injected only for authored lifetime-failure tests; live calls own one AUHAL.
@MainActor struct MacCoachingHALInputDriver {
    var create: @MainActor () throws -> AudioUnit
    var scalar: @MainActor (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement) -> UInt32?
    var setScalar: @MainActor (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32) -> OSStatus
    var format: @MainActor (AudioUnit) -> AudioStreamBasicDescription?
    var prepare: @MainActor (AudioUnit, AVAudioFormat, AURenderCallbackStruct) -> OSStatus
    var initialize: @MainActor (AudioUnit) -> OSStatus
    var start: @MainActor (AudioUnit) -> OSStatus
    var stop: @MainActor (AudioUnit) -> OSStatus
    var uninitialize: @MainActor (AudioUnit) -> OSStatus
    var dispose: @MainActor (AudioUnit) -> OSStatus

    static let live = Self(create: createUnit, scalar: { read($0, $1, $2, $3) },
        setScalar: { write($0, $1, $2, $3, $4) },
        format: { read($0, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1) },
        prepare: prepareUnit, initialize: AudioUnitInitialize, start: AudioOutputUnitStart,
        stop: AudioOutputUnitStop, uninitialize: AudioUnitUninitialize, dispose: AudioComponentInstanceDispose)

    private static func createUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoachingSafetyError.unsafeOutput
        }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else {
            throw CoachingSafetyError.unsafeOutput
        }
        return instance
    }

    private static func prepareUnit(_ unit: AudioUnit, format: AVAudioFormat,
                                    callback: AURenderCallbackStruct) -> OSStatus {
        let formatResult = write(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, format.streamDescription.pointee)
        guard formatResult == noErr else { return formatResult }
        let maximumResult = write(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                  kAudioUnitScope_Global, 0, UInt32(8_192))
        guard maximumResult == noErr else { return maximumResult }
        return write(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
    }

    private static func read<Value>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                                    _ scope: AudioUnitScope, _ bus: AudioUnitElement) -> Value? {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size,
                                                       alignment: MemoryLayout<Value>.alignment)
        defer { storage.deallocate() }
        var size = UInt32(MemoryLayout<Value>.size)
        guard AudioUnitGetProperty(unit, property, scope, bus, storage, &size) == noErr,
              size == MemoryLayout<Value>.size else { return nil }
        return storage.load(as: Value.self)
    }

    private static func write<Value>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                                     _ scope: AudioUnitScope, _ bus: AudioUnitElement, _ value: Value) -> OSStatus {
        var value = value
        return withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, bus, $0, UInt32(MemoryLayout<Value>.size))
        }
    }
}
#endif
