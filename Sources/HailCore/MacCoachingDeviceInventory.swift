#if os(macOS)
import CoreAudio
import Foundation

/// Display names and fresh runtime IDs only. The owner independently requalifies each selection at Start.
public struct MacCoachingDevice: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let name: String
    let uid: String
}

@MainActor
public enum MacCoachingDeviceInventory {
    public static func microphones() -> [MacCoachingDevice] {
        devices().filter { MacCoachingInputEvidence.read($0.id)?.uid == $0.uid }
    }

    public static func privateOutputs() -> [MacCoachingDevice] {
        devices().filter { MacCoachingDeviceEvidence.read($0.id)?.uid == $0.uid }
    }

    private static func devices() -> [MacCoachingDevice] {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let width = UInt32(MemoryLayout<UInt32>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0, size <= 128 * width, size.isMultiple(of: width) else { return [] }
        let expected = size
        var ids = [UInt32](repeating: 0, count: Int(size / width))
        let status: OSStatus = ids.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return -50 }
            return AudioObjectGetPropertyData(system, &property, 0, nil, &size, base)
        }
        guard status == noErr, size == expected, Set(ids).count == ids.count else { return [] }
        return ids.compactMap { id in
            guard let name = string(id, selector: kAudioObjectPropertyName),
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            return MacCoachingDevice(id: id, name: name, uid: uid)
        }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func string(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // Dedicated adapter storage for Core Audio's CFString reference ABI.
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, value) == noErr,
              size == MemoryLayout<CFString?>.size, let name = value.pointee else { return nil }
        return name as String
    }
}
#endif
