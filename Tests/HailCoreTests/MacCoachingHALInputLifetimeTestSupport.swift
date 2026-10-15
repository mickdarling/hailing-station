#if os(macOS)
import AudioToolbox
import AVFAudio
@testable import HailCore

/// Authored sentinel handle; every operation is injected. No native audio API receives this handle.
@MainActor final class HALInputLifetimeRig {
    var creates = 0
    var stops = 0, uninitializes = 0, disposes = 0
    var stopResult: OSStatus = noErr, uninitializeResult: OSStatus = noErr, disposeResult: OSStatus = noErr
    var prepareResult: OSStatus = noErr, initializeResult: OSStatus = noErr, startResult: OSStatus = noErr
    var enableResult: OSStatus = noErr
    var running: UInt32 = 0, device: UInt32 = 10
    var callback: AURenderCallbackStruct?
    var onStop: (@MainActor () -> Void)?
    let cleanup = MacCoachingInputCleanup()

    var driver: MacCoachingHALInputDriver {
        .init(create: {
            self.creates += 1
            guard let sentinel = AudioUnit(bitPattern: 1) else { throw CoachingSafetyError.unsafeOutput }
            return sentinel
        },
            scalar: { _, property, scope, _ in
                if property == kAudioOutputUnitProperty_EnableIO { return scope == kAudioUnitScope_Input ? 1 : 0 }
                return property == kAudioOutputUnitProperty_IsRunning ? self.running : self.device
            }, setScalar: { _, property, _, _, value in
                if property == kAudioOutputUnitProperty_CurrentDevice { self.device = value }
                return self.enableResult
            }, format: { _ in
                var format = AudioStreamBasicDescription()
                format.mSampleRate = 48_000; format.mChannelsPerFrame = 1
                return format
            }, prepare: { _, _, callback in self.callback = callback; return self.prepareResult },
            initialize: { _ in self.initializeResult },
            start: { _ in self.running = 1; return self.startResult },
            stop: { _ in
                self.stops += 1; self.onStop?()
                if self.stopResult == noErr { self.running = 0 }
                return self.stopResult
            },
            uninitialize: { _ in self.uninitializes += 1; return self.uninitializeResult },
            dispose: { _ in
                self.disposes += 1
                if self.disposeResult == noErr { self.callback = nil }
                return self.disposeResult
            })
    }

    func lateCallback() -> OSStatus {
        guard let callback, let invoke = callback.inputProc, let context = callback.inputProcRefCon else {
            return kAudio_ParamError
        }
        var flags = AudioUnitRenderActionFlags(), time = AudioTimeStamp()
        return invoke(context, &flags, &time, 1, 160, nil)
    }
}

let authoredHALInputCallback: AURenderCallback = { context, flags, time, _, frames, _ in
    Unmanaged<MacCoachingHALInputDelivery>.fromOpaque(context).takeUnretainedValue()
        .render(flags, time: time, frames: frames)
}
#endif
