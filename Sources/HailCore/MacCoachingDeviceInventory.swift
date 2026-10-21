#if os(macOS)
import CoreAudio
import Foundation

/// One choice in the Mac coaching card (#645). `name` is only a label; it never decides what qualifies.
/// `key` is the device UID: a private correlation for "same device as before", never shown or logged.
public struct MacCoachingDevice: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let name: String
    public let key: String
    public let transport: PrivateCoachingOutputTransport
}

/// Lists only devices the existing OS evidence readers qualify: outputs whose every stream is a headphones
/// terminal, and non-Bluetooth microphones. haild re-reads the same evidence by ID before it binds anything,
/// so a stale list can at worst be refused. The card re-lists just before Start to catch a reused ID.
@MainActor
public enum MacCoachingDeviceInventory {
    public static func privateOutputs() -> [MacCoachingDevice] {
        list(ids: MacCoachingHAL.deviceIDs(), name: MacCoachingHAL.name, transport: MacCoachingHAL.transport,
             qualifies: { MacCoachingDeviceEvidence.read($0)?.uid })
    }

    public static func roomMicrophones() -> [MacCoachingDevice] {
        list(ids: MacCoachingHAL.deviceIDs(), name: MacCoachingHAL.name, transport: MacCoachingHAL.transport,
             qualifies: { MacCoachingInputEvidence.read($0)?.uid })
    }

    static func list(ids: [UInt32], name: (UInt32) -> String?, transport: (UInt32) -> UInt32?,
                     qualifies: (UInt32) -> String?) -> [MacCoachingDevice] {
        ids.compactMap { id in
            guard let key = qualifies(id), !key.isEmpty else { return nil }
            let label = name(id).flatMap { $0.isEmpty ? nil : $0 } ?? "Audio device"
            return MacCoachingDevice(id: id, name: label, key: key, transport: kind(transport(id)))
        }
        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func kind(_ transport: UInt32?) -> PrivateCoachingOutputTransport {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        default: .other
        }
    }
}

/// Read-only HAL listing. It never selects, opens or changes a device.
@MainActor enum MacCoachingHAL {
    static func deviceIDs() -> [UInt32] {
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
        return ids
    }

    static func transport(_ device: UInt32) -> UInt32? {
        MacCoachingDeviceReader.live.scalar(device, kAudioDevicePropertyTransportType)
    }

    static func name(_ device: UInt32) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, value) == noErr,
              size == MemoryLayout<CFString?>.size, let name = value.pointee else { return nil }
        return String(String(name as String).prefix(64))
    }
}
#endif
