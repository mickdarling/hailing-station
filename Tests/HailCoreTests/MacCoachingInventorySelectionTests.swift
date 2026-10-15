#if os(macOS)
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingInventorySelectionTests {
    @Test func deviceIDReuseCannotRedirectAnExistingSelection() {
        let selected = MacCoachingDevice(id: 10, name: "Authored device", uid: "authored-original")
        let replacement = MacCoachingDevice(id: 10, name: selected.name, uid: "authored-replacement")
        #expect(MacCoachingDeviceInventory.retainedSelection(10, previous: [selected], current: [replacement]) == 0)
        #expect(MacCoachingDeviceInventory.retainedSelection(10, previous: [selected], current: []) == 0)
    }

    @Test func unchangedDeviceSurvivesReorderingButNewRuntimeIDRequiresSelection() {
        let selected = MacCoachingDevice(id: 10, name: "Authored device", uid: "authored-original")
        let other = MacCoachingDevice(id: 20, name: "Other authored device", uid: "authored-other")
        let reconnected = MacCoachingDevice(id: 30, name: selected.name, uid: selected.uid)
        #expect(MacCoachingDeviceInventory.retainedSelection(10, previous: [selected, other],
                                                            current: [other, selected]) == 10)
        #expect(MacCoachingDeviceInventory.retainedSelection(10, previous: [selected], current: [reconnected]) == 0)
        #expect(MacCoachingDeviceInventory.retainedSelection(0, previous: [], current: [selected]) == 0)
        #expect(MacCoachingDeviceInventory.retainedSelection(10, previous: [], current: [selected]) == 0)
    }
}
#endif
