#if os(macOS)
import AudioToolbox
import AVFAudio
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingHALInputLifetimeTests {
    @Test(arguments: [false, true], [false, true])
    func successfulDisposalReleasesContextEvenWhenEarlierTeardownNeedsRecovery(
        stopFails: Bool, uninitializeFails: Bool
    ) throws {
        let rig = HALInputLifetimeRig()
        rig.stopResult = stopFails ? -50 : noErr; rig.uninitializeResult = uninitializeFails ? -50 : noErr
        let unit = try MacCoachingHALInputUnit(driver: rig.driver, cleanup: rig.cleanup)
        weak let context = try prepare(unit)
        #expect(context != nil)
        #expect(unit.close())
        #expect(context == nil && !rig.cleanup.requiresAppRestart && rig.cleanup.retainedCount == 0)
        #expect(unit.close() && rig.stops == 1 && rig.uninitializes == 1 && rig.disposes == 1)
    }

    @Test func failedDisposalRetainsContextRejectsRestartAndMakesLateCallbackSafe() throws {
        let rig = HALInputLifetimeRig()
        rig.disposeResult = -50
        var unit: MacCoachingHALInputUnit? = try MacCoachingHALInputUnit(driver: rig.driver, cleanup: rig.cleanup)
        weak let context = try prepare(try #require(unit))
        #expect(unit?.close() == false)
        #expect(unit?.binding.currentDevice() == nil)
        #expect(throws: CoachingSafetyError.unsafeOutput) { try unit?.binding.setDevice(20) }
        unit = nil
        #expect(context != nil && context?.healthy == false)
        #expect(rig.cleanup.requiresAppRestart && rig.cleanup.retainedCount == 1)
        #expect(rig.lateCallback() == noErr)
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            _ = try MacCoachingHALInputUnit(driver: rig.driver, cleanup: rig.cleanup)
        }
        #expect(rig.creates == 1 && rig.disposes == 1) // Neither deinit nor a fresh request retries uncertain IO.
    }

    @Test(arguments: [false, true])
    func partiallyInstalledCallbackSurvivesFailedPreparationAndFailedDisposal(initializeFails: Bool) throws {
        let rig = HALInputLifetimeRig()
        rig.disposeResult = -50
        if initializeFails { rig.initializeResult = -50 } else { rig.prepareResult = -50 }
        var unit: MacCoachingHALInputUnit? = try MacCoachingHALInputUnit(driver: rig.driver, cleanup: rig.cleanup)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var context: MacCoachingHALInputDelivery? = .init(format: format, pull: { _, _, _, _ in
            Issue.record("Retired partial preparation cannot pull audio"); return -50
        })
        weak let retained = context
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            let context = try #require(context)
            try unit?.prepare(format: format, callback: callback(context), context: context)
        }
        context = nil; unit = nil
        #expect(retained != nil && retained?.healthy == false && rig.cleanup.requiresAppRestart)
        #expect(rig.lateCallback() == noErr && rig.disposes == 1)
    }

    @Test func constructorFailureUsesCheckedTeardownAndStartFailureOwnsItsPartialEffects() throws {
        let constructor = HALInputLifetimeRig()
        constructor.enableResult = -50; constructor.disposeResult = -50
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            _ = try MacCoachingHALInputUnit(driver: constructor.driver, cleanup: constructor.cleanup)
        }
        #expect(constructor.cleanup.requiresAppRestart && constructor.disposes == 1)
        let start = HALInputLifetimeRig()
        start.startResult = -50; start.stopResult = -50; start.disposeResult = -50
        let unit = try MacCoachingHALInputUnit(driver: start.driver, cleanup: start.cleanup)
        weak let context = try prepare(unit)
        #expect(throws: CoachingSafetyError.unsafeOutput) { try unit.start() }
        #expect(start.cleanup.requiresAppRestart && context?.healthy == false && start.disposes == 1)
        #expect(start.lateCallback() == noErr)
    }

    @Test func reentrantCloseCannotDisposeTwiceOrObserveAClosingBinding() throws {
        let rig = HALInputLifetimeRig()
        let unit = try MacCoachingHALInputUnit(driver: rig.driver, cleanup: rig.cleanup)
        rig.onStop = {
            #expect(!unit.close())
            #expect(unit.binding.currentDevice() == nil)
        }
        #expect(unit.close())
        rig.onStop = nil
        #expect(rig.stops == 1 && rig.uninitializes == 1 && rig.disposes == 1)
    }

    private func prepare(_ unit: MacCoachingHALInputUnit) throws -> MacCoachingHALInputDelivery {
        let format = try unit.inputFormat()
        let context = MacCoachingHALInputDelivery(format: format, pull: { _, _, _, _ in
            Issue.record("Retired unit cannot pull audio"); return -50
        })
        try unit.prepare(format: format, callback: callback(context), context: context)
        return context
    }
    private func callback(_ context: MacCoachingHALInputDelivery) -> AURenderCallbackStruct {
        AURenderCallbackStruct(inputProc: authoredHALInputCallback,
                              inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
    }
}
#endif
