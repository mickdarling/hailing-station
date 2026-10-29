import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectClosingPongTests {
    @Test func authorizationRefusalBeforeSelectionPongPreservesPrivateRunNotice() async throws {
        let run = try AmbientClosingSelectionRun()
        try await run.refusePrivateSelection()
        let rig = run.rig
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        let notice = try #require(rig.controller.reconnect.notice)
        #expect(notice.outcome == .blocked)
        #expect(notice.reason == .reauthorizationNeeded)
        #expect(notice.reason?.diagnosticToken == "reauthorization_needed")
        #expect(notice.text == "Listening stopped; re-authorization needed. Choose a destination to continue.")
        #expect(rig.notices.last == notice)
        #expect(!rig.controller.isListening && rig.unexpected.isEmpty)
        try await run.expectNoGapAudioOrPrivacyOff()
        await rig.close()
    }
}
