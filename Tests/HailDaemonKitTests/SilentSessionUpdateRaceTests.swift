import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateRaceTests {
    @Test func submissionDuringAnOutstandingDrainIsDeliveredOnceAfterIt() async throws {
        let rig = try await SilentUpdateRig.make()
        let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
        let first = Task {
            await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
                entered.release()
                await release.wait()
            }, operation: { await rig.submit() })
        }
        await entered.wait()
        #expect(await rig.submit().outcome == .held && rig.sends == 0)
        release.release()
        #expect(await first.value.outcome == .delivered)
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 2)
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 2)
        await rig.listener.stop()
    }

    @Test func configuringSpeechAtThePeerHopRefusesTheSilentAttempt() async throws {
        let rig = try await SilentUpdateRig.make()
        let report = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            await rig.listener.configureSessionUpdateSpeech(UnusedUpdateSpeech())
        }, operation: { await rig.submit() })
        #expect(report.outcome == .held && rig.sends == 0)
        #expect(await rig.listener.drainSessionUpdates(.interaction).count == 1 && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test func allExistingDrainTriggersLogEmptyCountsWithoutContent() async throws {
        let rig = try await SilentUpdateRig.make()
        for trigger in [SessionUpdateDrainTrigger.asked, .interaction, .naturalPause] {
            #expect(await rig.listener.drainSessionUpdates(trigger).isEmpty)
        }
        #expect(rig.drains == [
            "trigger=asked count=0", "trigger=interaction count=0", "trigger=natural_pause count=0"
        ])
        #expect(rig.sends == 0)
        await rig.listener.stop()
    }
}
