#if os(macOS)
import CoreAudio
import Foundation

/// Desktop AVAudioEngine capture uses the system route. This backend reports that route; it never changes it.
/// Fixed USB/private-output coaching owns separate engines and does not use this default-route adapter (#266).
@MainActor
public final class MacDefaultAudioSessionBackend: AudioSessionBackend {
    private let events: AsyncStream<AudioSessionBackendEvent>
    private var properties: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenerFailure = false
    private let readRoute: (Bool) -> (route: AudioSessionDiagnostics, inputReadFailed: Bool)
    private var lastRoute: AudioSessionDiagnostics?
    private let continuation: AsyncStream<AudioSessionBackendEvent>.Continuation

    public convenience init() { self.init(readRouteResult: Self.currentRoute, observe: true) }

    convenience init(readRoute: @escaping (Bool) -> AudioSessionDiagnostics, observe: Bool = false) {
        self.init(readRouteResult: { (readRoute($0), false) }, observe: observe)
    }

    init(readRouteResult: @escaping (Bool) -> (route: AudioSessionDiagnostics, inputReadFailed: Bool),
         observe: Bool = false) {
        self.readRoute = readRouteResult
        let pair = AsyncStream<AudioSessionBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = pair.stream
        continuation = pair.continuation
        guard observe else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let callback: AudioObjectPropertyListenerBlock = { _, _ in pair.continuation.yield(.routeChanged) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                  &address, .main, callback) == noErr {
                properties.append((address, callback))
            } else { listenerFailure = true }
        }
    }

    isolated deinit {
        for (var address, callback) in properties {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, callback)
        }
        continuation.finish()
    }

    public func configure(allowsBluetoothHFP: Bool) async throws {
        guard !listenerFailure else { throw AudioInputSelectionError.noSelectableInput }
    }
    public func setActive(_ active: Bool) async throws {}

    public func availableInputs() async -> [AudioPort] {
        route(isActive: false).input.map { [$0] } ?? []
    }

    public func selectInput(id: AudioPort.ID?) async throws {
        // Accept only the actual default: no pretend selection and no system-default setter.
        if let id, route(isActive: false).input?.id != id {
            throw AudioInputSelectionError.unavailable(id)
        }
    }

    public func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics { route(isActive: isActive) }

    private func route(isActive: Bool) -> AudioSessionDiagnostics {
        let reading = readRoute(isActive)
        if !reading.inputReadFailed {
            lastRoute = reading.route // A successful no-input read clears the cache too.
            return reading.route
        }
        return AudioSessionDiagnostics(isActive: isActive, input: lastRoute?.input,
            outputs: reading.route.outputs, sampleRate: lastRoute?.sampleRate ?? 0)
    }

    private static func currentRoute(_ isActive: Bool)
        -> (route: AudioSessionDiagnostics, inputReadFailed: Bool) {
        let input: (port: AudioPort, sampleRate: Double)?
        var inputReadFailed = false
        do {
            input = try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        } catch {
            input = nil
            inputReadFailed = true
        }
        let output = try? Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        return (AudioSessionDiagnostics(isActive: isActive, input: input?.port,
            outputs: output.map { [$0.port] } ?? [], sampleRate: input?.sampleRate ?? 0), inputReadFailed)
    }

    public func eventStream() async -> AsyncStream<AudioSessionBackendEvent> { events }

    private enum RouteReadFailure: Error { case unavailable }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector)
        throws -> (port: AudioPort, sampleRate: Double)? {
        var property = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &property, 0, nil, &size, &device)
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size else { throw RouteReadFailure.unavailable }
        guard device != kAudioObjectUnknown else { return nil }
        guard let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
              let name = string(device, selector: kAudioObjectPropertyName) else { throw RouteReadFailure.unavailable }
        var sampleRate: Double = 0
        property.mSelector = kAudioDevicePropertyNominalSampleRate
        size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &sampleRate) == noErr,
              size == MemoryLayout<Double>.size else { throw RouteReadFailure.unavailable }
        return (AudioPort(id: uid, name: name, kind: kind(device)), sampleRate)
    }

    private static func kind(_ device: AudioDeviceID) -> AudioInputKind {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &transport) == noErr else { return .other }
        return kind(for: transport)
    }

    static func kind(for transport: UInt32) -> AudioInputKind {
        switch transport {
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI: return .wired
        default: return .other
        }
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // Dedicated adapter storage for Core Audio's CFString reference ABI.
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, value) == noErr,
              size == MemoryLayout<CFString?>.size, let string = value.pointee else { return nil }
        return string as String
    }
}
#endif
