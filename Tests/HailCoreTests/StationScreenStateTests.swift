import Testing
@testable import HailCore

struct StationScreenStateTests {
    @Test func connectionAndDestinationAreIndependent() {
        for state: StationAvailability in [.ready, .chooseTarget, .noAllowedTargets, .waitingForTargets,
                                          .restoringSelection, .selectionFailed] {
            #expect(state.connectionLabel == "Connected")
        }
        #expect(StationAvailability.offline.connectionLabel == "Offline")
        #expect(StationAvailability.reconnecting.connectionLabel == "Reconnecting")
        #expect(StationAvailability.unconfigured.connectionLabel == "No Mac configured")
    }

    @Test func finishingOwnsTheTransitionEvenWhileRecordingIsStillSet() {
        #expect(TalkCapturePhase(starting: false, recording: false, finishing: false) == .idle)
        #expect(TalkCapturePhase(starting: true, recording: false, finishing: false) == .starting)
        #expect(TalkCapturePhase(starting: true, recording: true, finishing: false) == .recording)
        #expect(TalkCapturePhase(starting: false, recording: true, finishing: true) == .finishing)
    }

    @Test func turnEvidenceIsIndependentOfDisplayCopy() {
        let changed = StationTalkStatus.destinationChanged
        #expect(changed.outcome() == .notSent(reason: "the destination changed"))
        #expect(StationTalkStatus.message(changed.text).outcome() == nil)
        for outcome: TurnOutcome in [.sending, .waitingForReply, .replyReceived, .noReplyYet, .sentUnverified] {
            #expect(StationTalkStatus.turn(outcome, text: "Ready").outcome() == outcome)
            #expect(StationTalkStatus.turn(outcome, text: changed.text).outcome() == outcome)
        }
    }

    @Test func recoveryRequiresTheOwnersDeliveryEvidence() {
        let local = TurnOutcome.notSent(reason: "Paste rejected locally")
        let refused = TurnOutcome.refused(reason: "Refused by the selected Mac")
        let failed = StationTalkStatus.sendFailed("Waiting for reply")
        #expect(failed.outcome() == .sentUnverified)
        #expect(failed.outcome(pasteFailure: local) == local)
        #expect(StationTalkStatus.ready.outcome(pasteFailure: local) == nil)
        #expect(StationTalkStatus.ready.outcome(pasteFailure: refused) == refused)
        #expect(StationTalkStatus.turn(.sending, text: "Ready").outcome(pasteFailure: refused) == .sending)
    }
}
