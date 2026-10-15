#if os(macOS)
import AudioToolbox
import AVFAudio
import Foundation

/// A dedicated AUHAL, without AVAudioEngine's default-device aggregate/property-listener graph.
@MainActor final class MacCoachingHALInputUnit {
    let unit: AudioUnit
    private var prepared = false
    private var started = false
    private var disposed = false

    init() throws {
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
        unit = instance
        do {
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, value: UInt32(1))
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, value: UInt32(0))
            let input: UInt32? = get(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1)
            let output: UInt32? = get(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0)
            guard input == 1, output == 0, running() == 0 else { throw CoachingSafetyError.unsafeOutput }
        } catch { dispose(); throw error }
    }

    isolated deinit { dispose() }

    var binding: MacCoachingBindingOperations {
        .init(running: { self.started || self.running() != 0 }, setDevice: { device in
            guard !self.disposed, !self.prepared, !self.started else { throw CoachingSafetyError.unsafeOutput }
            try self.set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, value: device)
        }, currentDevice: {
            guard !self.disposed, !self.started || self.running() == 1 else { return nil }
            return self.get(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0)
        })
    }

    func inputFormat() throws -> AVAudioFormat {
        guard !disposed, !prepared, !started,
              let hardware: AudioStreamBasicDescription = get(kAudioUnitProperty_StreamFormat,
                  scope: kAudioUnitScope_Input, bus: 1), hardware.mSampleRate.isFinite,
              (16_000...192_000).contains(hardware.mSampleRate), (1...2).contains(hardware.mChannelsPerFrame),
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate,
                                         channels: hardware.mChannelsPerFrame) else {
            throw CoachingSafetyError.unsafeOutput
        }
        return format
    }

    func prepare(format: AVAudioFormat, callback: AURenderCallbackStruct) throws {
        guard !disposed, !prepared, !started else { throw CoachingSafetyError.unsafeOutput }
        try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, bus: 1,
                value: format.streamDescription.pointee)
        try set(kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, bus: 0, value: UInt32(8_192))
        try set(kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, bus: 0, value: callback)
        guard AudioUnitInitialize(unit) == noErr else { throw CoachingSafetyError.unsafeOutput }
        prepared = true
    }

    func start() throws {
        guard !disposed, prepared, !started, running() == 0 else { throw CoachingSafetyError.unsafeOutput }
        started = true // Partial startup owns cleanup too.
        guard AudioOutputUnitStart(unit) == noErr, running() == 1 else {
            stop(); throw CoachingSafetyError.unsafeOutput
        }
    }

    func stop() {
        guard !disposed else { return }
        started = false
        AudioOutputUnitStop(unit)
    }

    func dispose() {
        guard !disposed else { return }
        stop()
        disposed = true
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func running() -> UInt32? {
        guard !disposed, let value: UInt32 = get(kAudioOutputUnitProperty_IsRunning,
            scope: kAudioUnitScope_Global, bus: 0), value <= 1 else { return nil }
        return value
    }

    private func get<Value>(_ property: AudioUnitPropertyID, scope: AudioUnitScope,
                            bus: AudioUnitElement) -> Value? {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size,
                                                       alignment: MemoryLayout<Value>.alignment)
        defer { storage.deallocate() }
        var size = UInt32(MemoryLayout<Value>.size)
        guard AudioUnitGetProperty(unit, property, scope, bus, storage, &size) == noErr,
              size == MemoryLayout<Value>.size else { return nil }
        return storage.load(as: Value.self)
    }

    private func set<Value>(_ property: AudioUnitPropertyID, scope: AudioUnitScope,
                            bus: AudioUnitElement, value: Value) throws {
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, bus, $0, UInt32(MemoryLayout<Value>.size))
        }
        guard status == noErr else { throw CoachingSafetyError.unsafeOutput }
    }
}
#endif
