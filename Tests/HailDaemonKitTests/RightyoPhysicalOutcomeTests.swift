import Foundation
import Testing
@testable import HailDaemonKit

extension RightyoRequestOutcomeTests {
    @Test(arguments: [RightyoRequestOutcomeState.cancelled, .failed, .timedOut])
    func aPhysicalSpanMustEndBeforeAnyTerminalFailure(_ failure: RightyoRequestOutcomeState) throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session), host = UUID()
        ledger.observe(try started())
        #expect(ledger.register(host: host, producer: "tool-demo:request"))
        #expect(ledger.report(.accepted, host: host, write: { _ in true }))
        ledger.observe(try ack())
        #expect(ledger.report(.replyStarted, host: host, write: { _ in true }))
        ledger.observe(try ack("reply_started", sequence: 6))
        #expect(!ledger.report(failure, host: host, write: { _ in
            Issue.record("physical span must finish before failure"); return true
        }))
        #expect(ledger.report(.replyEnded, host: host, write: { _ in true }))
        ledger.observe(try ack("reply_ended", sequence: 7))
        #expect(ledger.isConfirmed(host, .replyEnded))
    }
    @Test func scopedPlaybackCannotSwitchToPublicationAndStrandItsPhysicalEnd() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session), host = UUID()
        ledger.observe(try started())
        #expect(ledger.register(host: host, producer: "tool-demo:request"))
        #expect(ledger.report(.accepted, host: host, write: { _ in true }))
        ledger.observe(try ack())
        #expect(ledger.report(.replyStarted, host: host, write: { _ in true }))
        ledger.observe(try ack("reply_started", sequence: 6))
        #expect(!ledger.report(.replyPublished, host: host, write: { _ in
            Issue.record("mixed completion must not be written"); return true
        }))
        #expect(ledger.report(.replyEnded, host: host, write: { _ in true }))
        ledger.observe(try ack("reply_ended", sequence: 7))
        #expect(ledger.isConfirmed(host, .replyEnded))
    }
}
