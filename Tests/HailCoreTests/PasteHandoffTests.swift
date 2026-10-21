import Foundation
import Testing
@testable import HailCore

/// #636 follow-up to #716: a reply placed while a send's write is still going ends its wait, so Talk and Send Paste
/// come back before that write returns. Neither may send its paste a second time, and the paste it carried is cleared
/// when the write returns, whatever the station did in between. Synthetic text only.
@Suite struct PasteHandoffTests {
    @Test func aSendStartedWhileAnEarlierWriteIsInFlightDoesNotCarryItsPaste() throws {
        var handoff = PasteHandoff()
        let paste = try PastedDraft("note")
        handoff.attach(paste)
        let (first, second) = (UUID(), UUID())
        #expect(handoff.take(for: first) == paste)
        #expect(handoff.isCarried)
        #expect(handoff.take(for: second) == nil)
        #expect(handoff.attached == paste)
    }

    @Test func aDeliveredPasteIsClearedEvenAfterANewerSendStarted() throws {
        var handoff = PasteHandoff()
        handoff.attach(try PastedDraft("note"))
        let (first, second) = (UUID(), UUID())
        _ = handoff.take(for: first)
        _ = handoff.take(for: second)
        handoff.finish(second, delivered: true)
        handoff.finish(first, delivered: true)
        #expect(handoff.attached == nil)
        #expect(!handoff.isCarried)
    }

    @Test func aFailedSendLeavesItsPasteAttachedForTheNextRequest() throws {
        var handoff = PasteHandoff()
        let paste = try PastedDraft("note")
        handoff.attach(paste)
        let first = UUID()
        _ = handoff.take(for: first)
        handoff.finish(first, delivered: false)
        #expect(handoff.attached == paste)
        #expect(!handoff.isCarried)
        #expect(handoff.take(for: UUID()) == paste)
    }

    @Test func aRefusedPasteStaysWhenItsWriteReturns() throws {
        var handoff = PasteHandoff()
        handoff.attach(try PastedDraft("note"))
        let first = UUID()
        _ = handoff.take(for: first)
        let restored = try PastedDraft("note")
        handoff.restore(restored, refusing: first)
        handoff.finish(first, delivered: true)
        #expect(handoff.attached == restored)
        #expect(handoff.take(for: UUID()) == restored)
    }

    @Test func aPasteAttachedAgainDuringTheWriteIsKeptEvenWithTheSameText() throws {
        var handoff = PasteHandoff()
        handoff.attach(try PastedDraft("note"))
        let first = UUID()
        _ = handoff.take(for: first)
        handoff.attach(nil)
        let again = try PastedDraft("note")
        handoff.attach(again)
        #expect(!handoff.isCarried)
        handoff.finish(first, delivered: true)
        #expect(handoff.attached == again)
    }

    @Test func aPasteRemovedDuringTheWriteStaysRemoved() throws {
        var handoff = PasteHandoff()
        handoff.attach(try PastedDraft("note"))
        let first = UUID()
        _ = handoff.take(for: first)
        handoff.attach(nil)
        handoff.finish(first, delivered: false)
        #expect(handoff.attached == nil)
    }
}
