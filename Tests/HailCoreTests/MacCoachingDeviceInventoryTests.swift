#if os(macOS)
import CoreAudio
import Foundation
@testable import HailCore
import Testing

@Suite("Mac coaching device inventory (#645)") @MainActor
struct MacCoachingDeviceInventoryTests {
    @Test func onlyQualifiedDevicesAreListedAndNamesNeverQualify() {
        // Device 3 is named like headphones but has no OS evidence; device 4 qualifies under a plain name.
        let names: [UInt32: String] = [3: "Authored Headphones", 4: "Authored output"]
        let keys: [UInt32: String] = [4: "authored.key.4"]
        let listed = MacCoachingDeviceInventory.list(
            ids: [3, 4], name: { names[$0] }, transport: { _ in kAudioDeviceTransportTypeUSB },
            qualifies: { keys[$0] })
        #expect(listed.map(\.id) == [4])
        #expect(listed.first?.key == "authored.key.4")
        #expect(listed.first?.transport == .usb)
    }

    @Test func transportsMapToTheHeadphoneCheckClasses() {
        #expect(MacCoachingDeviceInventory.kind(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(MacCoachingDeviceInventory.kind(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(MacCoachingDeviceInventory.kind(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(MacCoachingDeviceInventory.kind(kAudioDeviceTransportTypeUSB) == .usb)
        #expect(MacCoachingDeviceInventory.kind(kAudioDeviceTransportTypeHDMI) == .other)
        #expect(MacCoachingDeviceInventory.kind(nil) == .other)
    }

    @Test func aReusedIDWithAnotherKeyIsADifferentChoice() {
        let first = MacCoachingDeviceInventory.list(ids: [7], name: { _ in "Authored" }, transport: { _ in nil },
                                                    qualifies: { _ in "authored.original" })
        let later = MacCoachingDeviceInventory.list(ids: [7], name: { _ in "Authored" }, transport: { _ in nil },
                                                    qualifies: { _ in "authored.replacement" })
        #expect(first.first != nil && !later.contains(first[0]))
    }

    @Test func missingNamesGetANeutralLabelAndOrderIsStable() {
        let listed = MacCoachingDeviceInventory.list(
            ids: [9, 8, 5], name: { $0 == 5 ? nil : "Authored \($0)" }, transport: { _ in nil },
            qualifies: { "authored.\($0)" })
        #expect(listed.map(\.name) == ["Audio device", "Authored 8", "Authored 9"])
    }
}
#endif
