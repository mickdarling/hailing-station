import Testing
@testable import HailCore

@Suite("Recovery sheet (#1115)")
struct RecoverySheetStateTests {
    private typealias Fixture = RecoveryFixtures

    @Test func everyStepConfirmedWithNoRequestInDoubtIsRestored() {
        let state = Fixture.resolve(turn: .replyReceived)
        #expect(state.header == "Restored")
        #expect(state.steps.map(\.state) == [.confirmed, .confirmed, .confirmed, .confirmed])
        #expect(state.request == "A reply arrived for the last request.")
        #expect(!state.requestNeedsAttention)
        #expect(state.intents == [.inspectConnection])
    }

    // Jarvis, PR 7 plan: a request in doubt keeps the sheet from reading as all-clear.
    @Test func aRequestInDoubtReadsConnectionRestored() {
        for turn: TurnOutcome in [.noReplyYet, .sentUnverified, .notSent(reason: "x"), .refused(reason: "x")] {
            let state = Fixture.resolve(turn: turn)
            #expect(state.header == "Connection restored", "\(turn)")
            #expect(state.requestNeedsAttention, "\(turn)")
            #expect(state.nextStep != nil, "\(turn)")
        }
        #expect(Fixture.resolve(turn: .waitingForReply).header == "Connection restored")
    }

    @Test func noReplyYetSaysNothingWasResent() {
        let state = Fixture.resolve(turn: .noReplyYet)
        #expect(state.request == "The last request was sent. No reply has arrived, and nothing was resent.")
        #expect(state.nextStep == "Check the session on the Mac before talking again.")
    }

    // Jarvis, PR 7 plan: only a request that never left the device says nothing was sent, and the prompt line claims
    // only what Hailing Station did.
    @Test func notSentAndRefusedClaimOnlyWhatTheStationDid() {
        let notSent = Fixture.resolve(turn: .notSent(reason: "Destination changed"))
        #expect(notSent.request == "Nothing was sent: Destination changed. "
            + "Hailing Station didn't change any text already in the Mac's prompt.")
        let refused = Fixture.resolve(turn: .refused(reason: "The target's input already holds unsent text."))
        #expect(refused.request?.hasPrefix("The Mac refused the last request: The target's input") == true)
        #expect(refused.request?.contains("Nothing was sent") == false)
        #expect(refused.nextStep == "Check the Mac before talking again.")
    }

    // Jarvis, PR 7 plan: a confirmed mode always names itself, and pending or unknown privacy is never confirmed.
    @Test func theModeRowNamesTheMode() {
        let mode = { (privacy: RailPrivacy?) in Fixture.resolve(privacy: privacy).steps[2] }
        #expect(mode(.unsupported).text == "This Mac has no privacy mode, so everything heard is sent.")
        #expect(mode(Fixture.privacy(on: true)).text == "Private: the Mac confirmed privacy.")
        #expect(mode(Fixture.privacy(on: false)).text == "Privacy is off, so what's heard is sent.")
        #expect(mode(nil).state == .waiting)
        #expect(mode(Fixture.unconfirmed).state == .waiting)
        #expect(mode(Fixture.privacy(on: true, requested: true)).state == .waiting)
        #expect(mode(Fixture.privacy(on: true, stopped: true)).state == .failed)
    }

    @Test func aFailedStepNeedsAttentionAndOffersItsChoice() {
        let offline = Fixture.resolve(.offline, destination: .unavailable(.offline, saved: Fixture.build))
        #expect(offline.header == "Needs attention")
        #expect(offline.intents == [.inspectConnection, .chooseDestination])
        let stopped = Fixture.resolve(listening: .off)
        #expect(stopped.header == "Needs attention")
        #expect(stopped.intents == [.inspectConnection, .openListening])
    }

    @Test func listeningThatWasOffIsNotNeeded() {
        let state = Fixture.resolve(listening: .off, wasListening: false)
        #expect(state.steps[3].state == .notApplicable)
        #expect(state.header == "Restored")
        #expect(!state.intents.contains(.openListening))
    }

    // Codex review of #1162: identical target names on two Macs must never read the same.
    @Test func theDestinationRowNamesItsMac() {
        let other = DestinationLabel(hostName: "Laptop", targetName: "build", targetKind: "tmux", targetID: "%1")
        let studio = Fixture.resolve(destination: .confirmed(Fixture.build)).steps[1].text
        let laptop = Fixture.resolve(destination: .confirmed(other)).steps[1].text
        #expect(studio == "Terminal · build · Mac Studio")
        #expect(studio != laptop)
        let saved = Fixture.resolve(destination: .confirming(saved: other)).steps[1]
        #expect(saved.text == "Confirming… Saved · not confirmed: Mac Laptop, Terminal build")
    }

    // Jarvis, PR 7 review: ready but not yet re-confirmed waits, rather than flashing "Needs attention".
    @Test func anUnconfirmedDestinationAfterAReconnectWaits() {
        let state = Fixture.resolve(destination: .unavailable(.unconfirmed, saved: Fixture.build))
        #expect(state.steps[1].state == .waiting)
        #expect(state.header == "Restoring…")
        #expect(state.intents.contains(.chooseDestination))
    }

    @Test func aStepStillWaitingReadsRestoring() {
        let state = Fixture.resolve(.reconnecting, destination: .confirming(saved: Fixture.build))
        #expect(state.header == "Restoring…")
        #expect(state.steps[0].text == "Reconnecting…")
    }
}
