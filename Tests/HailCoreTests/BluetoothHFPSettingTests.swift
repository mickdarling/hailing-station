import Testing
@testable import HailCore

extension AudioPort {
    static let hfp = AudioPort(id: "hfp", name: "AirPods", kind: .bluetoothHFP)
}

/// The owner's Bluetooth headset microphone setting (#905), applied live through the session's configure and
/// route-change path.
struct BluetoothHFPSettingTests {
    private func session(
        _ inputs: [AudioPort], allows: Bool = false
    ) -> (FakeAudioSessionBackend, ManagedAudioSession) {
        let backend = FakeAudioSessionBackend(inputs: inputs)
        let controller = ManagedAudioSession(
            backend: backend, preferences: AudioInputPreferences(allowsBluetoothHFP: allows),
            preferenceStore: VolatileAudioInputPreferenceStore()
        )
        return (backend, controller)
    }

    @Test func toggleChangesTheConfigureFlagLive() async throws {
        let (backend, controller) = session([.builtIn])
        try await controller.activate()
        #expect(await backend.configurations == [false])

        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.configurations == [false, true])
        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.configurations == [false, true])
        try await controller.setAllowsBluetoothHFP(false)
        #expect(await backend.configurations == [false, true, false])
        #expect(await backend.activationHistory == [true])
    }

    @Test func inactiveToggleReachesTheSharedCategoryWithoutActivating() async throws {
        let (backend, controller) = session([.builtIn])
        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.idleConfigurations == [true])
        #expect(await backend.configurations.isEmpty)
        try await controller.activate()
        #expect(await backend.configurations == [true])

        await controller.deactivate()
        try await controller.setAllowsBluetoothHFP(false)
        #expect(await backend.idleConfigurations == [true, false])
        #expect(await backend.configurations == [true])
        #expect(await backend.activationHistory == [true, false])
        try await controller.activate()
        #expect(await backend.configurations == [true, false])
        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.idleConfigurations == [true, false])
    }

    @Test func headsetMicIsSelectableOnlyWhileAllowed() async throws {
        let (_, controller) = session([.builtIn, .hfp])
        try await controller.activate()
        #expect(await controller.availableInputs == [.builtIn])
        await #expect(throws: AudioInputSelectionError.unavailable(AudioPort.hfp.id)) {
            try await controller.selectInput(id: AudioPort.hfp.id)
        }

        try await controller.setAllowsBluetoothHFP(true)
        #expect(await controller.availableInputs == [.builtIn, .hfp])
        try await controller.setAllowsBluetoothHFP(false)
        #expect(await controller.availableInputs == [.builtIn])
    }

    @Test func allowingTheHeadsetUsesItBeforeTheBuiltInMicButNotBeforeUSB() async throws {
        let (backend, controller) = session([.builtIn, .hfp])
        try await controller.activate()
        #expect(await backend.selectedInput == .builtIn)
        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.selectedInput == .hfp)
        #expect(await controller.diagnostics.input == .hfp)

        let (usbBackend, usbController) = session([.usb, .hfp, .builtIn])
        try await usbController.activate()
        try await usbController.setAllowsBluetoothHFP(true)
        #expect(await usbBackend.selectedInput == .usb)
        #expect(await usbBackend.selectionCount == 1)
    }

    @Test func turningItOffMovesAnAutomaticHeadsetMicToTheNextInput() async throws {
        let (backend, controller) = session([.builtIn, .hfp], allows: true)
        try await controller.activate()
        #expect(await backend.selectedInput == .hfp)

        try await controller.setAllowsBluetoothHFP(false)
        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.diagnostics.input == .builtIn)
        #expect(await controller.inputSelectionState.resolution == .automatic)
    }

    @Test func turningItOffKeepsTheOwnersHeadsetChoiceForLater() async throws {
        let (backend, controller) = session([.usb, .hfp, .builtIn], allows: true)
        try await controller.activate()
        try await controller.selectInput(id: AudioPort.hfp.id)
        #expect(await backend.selectedInput == .hfp)

        try await controller.setAllowsBluetoothHFP(false)
        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == .hfp)
        #expect(await controller.inputSelectionState.resolution == .fallback)

        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.selectedInput == .hfp)
        #expect(await controller.inputSelectionState.resolution == .confirmed)
    }

    @Test func allowingTheHeadsetNeverOverridesTheOwnersBuiltInChoice() async throws {
        let (backend, controller) = session([.builtIn, .hfp])
        try await controller.activate()
        try await controller.selectInput(id: AudioPort.builtIn.id)
        let selections = await backend.selectionCount

        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.selectedInput == .builtIn)
        #expect(await backend.selectionCount == selections)
        #expect(await controller.inputSelectionState.resolution == .confirmed)
    }

    @Test func turningItOffDuringAHeadsetSelectionLeavesTheHeadsetWhenItFinishes() async throws {
        let (backend, controller) = session([.usb, .hfp, .builtIn], allows: true)
        try await controller.activate()
        await backend.holdNextSelectionCall()
        let choice = Task { try await controller.selectInput(id: AudioPort.hfp.id) }
        await backend.waitUntilSelectionIsHeld()

        try await controller.setAllowsBluetoothHFP(false)
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.self) { try await choice.value }
        #expect(await backend.selectedInput == .usb)
        #expect(await controller.diagnostics.input == .usb)
    }

    @Test func toggleDuringAnInterruptionConfiguresAndTheResumeFollowsIt() async throws {
        let (backend, controller) = session([.builtIn, .hfp])
        try await controller.activate()
        await controller.handle(.interruptionBegan)

        try await controller.setAllowsBluetoothHFP(true)
        #expect(await backend.configurations == [false, true])
        #expect(await backend.activationHistory == [true])
        #expect(await controller.diagnostics.isActive == false)

        await controller.handle(.interruptionEnded(shouldResume: true))
        #expect(await backend.selectedInput == .hfp)
    }

    @Test func refusedCategoryStillLeavesAHeadsetMicThatIsNoLongerAllowed() async throws {
        let (backend, controller) = session([.builtIn, .hfp], allows: true)
        try await controller.activate()
        #expect(await backend.selectedInput == .hfp)
        await backend.refuseConfigurations(true)

        await #expect(throws: FakeConfigurationError.refused) {
            try await controller.setAllowsBluetoothHFP(false)
        }
        #expect(await backend.selectedInput == .builtIn)

        await backend.refuseConfigurations(false)
        await controller.deactivate()
        try await controller.activate()
        #expect(await backend.configurations.last == false)
    }
}
