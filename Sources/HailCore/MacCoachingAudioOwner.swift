#if os(macOS)
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

struct MacCoachingInputEvidence: Equatable, Sendable {
    let deviceID: UInt32
    let uid: String
    let streams: [UInt32]

    @MainActor static func read(
        _ device: UInt32, reader: MacCoachingDeviceReader = .live,
        inputs: @MainActor (UInt32) -> [UInt32]? = liveInputs
    ) -> Self? {
        guard device != kAudioObjectUnknown,
              reader.scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1,
              reader.scalar(device, kAudioObjectPropertyClass) == kAudioDeviceClassID,
              let transport = reader.scalar(device, kAudioDevicePropertyTransportType),
              transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual,
              transport != kAudioDeviceTransportTypeBluetooth, transport != kAudioDeviceTransportTypeBluetoothLE,
              let uid = reader.uid(device), !uid.isEmpty,
              let streams = inputs(device), !streams.isEmpty, streams.count <= 32,
              Set(streams).count == streams.count, streams.allSatisfy({ stream in
                  stream != kAudioObjectUnknown && reader.scalar(stream, kAudioStreamPropertyDirection) == 1
                      && reader.scalar(stream, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeMicrophone
              }), reader.scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
        return Self(deviceID: device, uid: uid, streams: streams)
    }

    private static func liveInputs(_ device: UInt32) -> [UInt32]? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let width = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size > 0, size <= 32 * width, size.isMultiple(of: width) else { return nil }
        let expected = size
        var values = [UInt32](repeating: 0, count: Int(size / width))
        let status: OSStatus = values.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return -50 }
            return AudioObjectGetPropertyData(device, &property, 0, nil, &size, base)
        }
        return status == noErr && size == expected ? values : nil
    }
}

@MainActor struct MacCoachingEngineLifetime {
    var start: () throws -> Void
    var stop: () -> Void
    var running: () -> Bool

    static func live(_ engine: AVAudioEngine) -> Self {
        Self(start: { engine.prepare(); try engine.start() }, stop: { engine.stop() }, running: { engine.isRunning })
    }
}

/// Owns separate fixed-output and raw room-microphone engines. Only explicit core begin invokes start.
@MainActor final class MacCoachingAudioOwner: AudioCapturing {
    let input: MacCoachingInputEvidence
    private let capture: any AudioCapturing
    private let output: MacCoachingEngineLifetime
    private let bound: () -> Bool
    private var ownedRevision: UUID?

    init(input: MacCoachingInputEvidence, capture: any AudioCapturing,
         output: MacCoachingEngineLifetime, bound: @escaping () -> Bool) {
        self.input = input
        self.capture = capture
        self.output = output
        self.bound = bound
    }

    isolated deinit { stop() }

    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard ownedRevision == nil, !output.running(), bound(),
              !output.running(), ownedRevision == nil else { throw CoachingSafetyError.unsafeOutput }
        let revision = UUID()
        ownedRevision = revision // A partially failed start owns both cleanups.
        do {
            try output.start()
            guard ownedRevision == revision, output.running(), bound(),
                  ownedRevision == revision, output.running() else { throw CoachingSafetyError.unsafeOutput }
            let stream = try capture.start()
            guard ownedRevision == revision, output.running(), bound(),
                  ownedRevision == revision, output.running() else { throw CoachingSafetyError.unsafeOutput }
            return stream
        } catch {
            if ownedRevision == revision { stop() }
            throw error
        }
    }

    func stop() {
        guard ownedRevision != nil else { return }
        ownedRevision = nil
        capture.stop()
        output.stop()
    }

    func isStillBound() -> Bool { bound() }

    static func live(inputEngine: AVAudioEngine, outputEngine: AVAudioEngine,
                     microphoneID: UInt32, outputBinding: MacCoachingOutputBinding) throws -> Self {
        guard !inputEngine.isRunning, let original = MacCoachingInputEvidence.read(microphoneID) else {
            throw CoachingSafetyError.unsafeOutput
        }
        let bound = try bindInput(original, read: { MacCoachingInputEvidence.read(microphoneID) },
            operations: inputBinding(inputEngine), output: { outputBinding.isStillBound() })
        return Self(input: original, capture: AVAudioEngineCapture(engine: inputEngine),
                    output: .live(outputEngine), bound: bound)
    }

    static func bindInput(_ original: MacCoachingInputEvidence,
                          read: @escaping () -> MacCoachingInputEvidence?, operations: MacCoachingBindingOperations,
                          output: @escaping () -> Bool) throws -> (() -> Bool) {
        guard !operations.running(), read() == original, !operations.running() else {
            throw CoachingSafetyError.unsafeOutput
        }
        try operations.setDevice(original.deviceID)
        var retired = false
        let bound: () -> Bool = {
            guard !retired, operations.currentDevice() == original.deviceID, read() == original,
                  operations.currentDevice() == original.deviceID, output(), !retired else {
                retired = true
                return false
            }
            return true
        }
        guard !operations.running(), bound(), !operations.running(), !retired else {
            throw CoachingSafetyError.unsafeOutput
        }
        return bound
    }

    private static func inputBinding(_ engine: AVAudioEngine) throws -> MacCoachingBindingOperations {
        guard let unit = engine.inputNode.audioUnit else { throw CoachingSafetyError.unsafeOutput }
        var description = AudioComponentDescription()
        guard AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) == noErr,
              description.componentType == kAudioUnitType_Output,
              description.componentSubType == kAudioUnitSubType_HALOutput else {
            throw CoachingSafetyError.unsafeOutput
        }
        return .init(running: { engine.isRunning }, setDevice: { device in
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

extension ApplePrivateCoaching {
    /// Local operator IDs, not a remote requested route. No IO starts until consent-confirmed begin.
    /// AirPods are conditional on independent OS headphone terminal evidence plus actual fixed HAL readback.
    public convenience init(privateOutputDeviceID: UInt32, roomMicrophoneDeviceID: UInt32,
                            listenerID: String, hooks: PrivateCoachingSession.Hooks) throws {
        guard privateOutputDeviceID != kAudioObjectUnknown, roomMicrophoneDeviceID != kAudioObjectUnknown,
              privateOutputDeviceID != roomMicrophoneDeviceID else { throw CoachingSafetyError.unsafeOutput }
        let outputEngine = AVAudioEngine()
        let inputEngine = AVAudioEngine()
        guard let evidence = MacCoachingDeviceEvidence.read(privateOutputDeviceID) else {
            throw CoachingSafetyError.unsafeOutput
        }
        let binding = try MacCoachingOutputBinding(deviceID: privateOutputDeviceID,
            read: { MacCoachingDeviceEvidence.read(privateOutputDeviceID) },
            operations: .live(engine: outputEngine))
        let owner = try MacCoachingAudioOwner.live(inputEngine: inputEngine, outputEngine: outputEngine,
                                                  microphoneID: roomMicrophoneDeviceID, outputBinding: binding)
        let monitor = try MacCoachingOutputMonitor.live(owner: owner, output: evidence)
        let player = CoachingEngineRenderer(operations: .live(engine: outputEngine), observe: { monitor.observe() })
        try self.init(capture: owner, player: player, monitor: monitor, listenerID: listenerID, hooks: hooks)
    }
}
#endif
