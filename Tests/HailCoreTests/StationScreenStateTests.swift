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

    @Test func recoveryRequiresTheOwnersDeliveryEvidence() {
        #expect(TurnOutcome.observed(status: "Listening") == nil)
        #expect(TurnOutcome.observed(status: "Sending…") == .sending)
        #expect(TurnOutcome.observed(status: "Waiting for reply…") == .waitingForReply)
        #expect(TurnOutcome.observed(status: "Reply received") == .replyReceived)
        #expect(TurnOutcome.observed(status: "No reply yet — tap to talk again") == .noReplyYet)
        #expect(TurnOutcome.observed(status: "Send failed: write failed") == .sentUnverified)
        #expect(TurnOutcome.observed(status: "Reply received — turn unverified") == .sentUnverified)
        let changed = "Destination changed — request not sent"
        #expect(TurnOutcome.observed(status: changed) == .notSent(reason: changed))
    }
}
