#if os(macOS)
import CoreAudio
import Foundation

/// Local hardware evidence only. Never a product-name/transport heuristic or a wire-issued grant.
struct MacCoachingDeviceEvidence: Equatable, Sendable {
    let deviceID: AudioObjectID
    let uid: String
    let streams: [AudioObjectID]

    @MainActor static func read(_ device: AudioObjectID, using reader: MacCoachingDeviceReader = .live) -> Self? {
        guard device != kAudioObjectUnknown,
              reader.scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1,
              reader.scalar(device, kAudioObjectPropertyClass) == kAudioDeviceClassID,
              let transport = reader.scalar(device, kAudioDevicePropertyTransportType),
              transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual,
              let uid = reader.uid(device), !uid.isEmpty,
              let streams = reader.outputs(device), !streams.isEmpty, streams.count <= 32,
              Set(streams).count == streams.count,
              streams.allSatisfy({ stream in
                  stream != kAudioObjectUnknown
                      && reader.scalar(stream, kAudioStreamPropertyDirection) == 0
                      && reader.scalar(stream, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeHeadphones
              }), reader.scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
        return Self(deviceID: device, uid: uid, streams: streams)
    }
}

/// Read-only HAL calls. Seams permit synthetic property tests without selecting or opening audio devices.
@MainActor struct MacCoachingDeviceReader {
    var scalar: @MainActor (AudioObjectID, AudioObjectPropertySelector) -> UInt32?
    var uid: @MainActor (AudioObjectID) -> String?
    var outputs: @MainActor (AudioObjectID) -> [AudioObjectID]?

    static let live = Self(scalar: readScalar, uid: readUID, outputs: readOutputs)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readScalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func readUID(_ object: AudioObjectID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, value) == noErr,
              size == MemoryLayout<CFString?>.size, let uid = value.pointee else { return nil }
        return uid as String
    }

    private static func readOutputs(_ object: AudioObjectID) -> [AudioObjectID]? {
        var property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        let width = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size > 0, size <= 32 * width, size.isMultiple(of: width) else { return nil }
        let expected = size
        var values = [AudioObjectID](repeating: 0, count: Int(size / width))
        let status: OSStatus = values.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return -50 }
            return AudioObjectGetPropertyData(object, &property, 0, nil, &size, base)
        }
        guard status == noErr, size == expected else { return nil }
        return values
    }
}
#endif
