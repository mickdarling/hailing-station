import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct SessionUpdateShapeTests {
    let now = ContinuousClock().now

    @Test func fieldsAreTrimmedAndBounded() {
        let made = SessionUpdate(session: " Jarvis ", priority: .info, spoken: " Done. ", card: "  ", submitted: now)
        #expect(made?.session == "Jarvis")
        #expect(made?.spoken == "Done.")
        #expect(made?.card == nil, "a blank card is no card")
        #expect(SessionUpdate(session: "", priority: .info, spoken: "Done", submitted: now) == nil)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: "  ", submitted: now) == nil)
        let long = String(repeating: "a", count: SessionUpdate.maxSpokenBytes + 1)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: long, submitted: now) == nil)
        let card = String(repeating: "c", count: SessionUpdate.maxCardBytes + 1)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: "ok", card: card, submitted: now) == nil)
    }

    @Test func digestNamesEachSpeaker() throws {
        #expect(SessionUpdateQueue.digest([]) == nil)
        let one = try #require(SessionUpdate(session: "Jarvis", priority: .info, spoken: "PR is green", submitted: now))
        #expect(SessionUpdateQueue.digest([one]) == "Jarvis: PR is green.")
        let two = try #require(SessionUpdate(session: "Voice Work", priority: .action, spoken: "Need a decision?",
                                             submitted: now))
        #expect(SessionUpdateQueue.digest([two, one])
                == "You have 2 updates. Voice Work: Need a decision? Jarvis: PR is green.")
    }

    @Test func quietHoursWrapMidnight() throws {
        let night = try #require(SessionUpdateQuietHours(start: 22 * 60, end: 7 * 60))
        #expect(night.contains(minuteOfDay: 23 * 60))
        #expect(night.contains(minuteOfDay: 6 * 60 + 59))
        #expect(!night.contains(minuteOfDay: 7 * 60))
        #expect(!night.contains(minuteOfDay: 12 * 60))
        let lunch = try #require(SessionUpdateQuietHours(start: 12 * 60, end: 13 * 60))
        #expect(lunch.contains(minuteOfDay: 12 * 60 + 30))
        #expect(!lunch.contains(minuteOfDay: 13 * 60))
        #expect(SessionUpdateQuietHours(start: 0, end: 0)?.contains(minuteOfDay: 0) == false)
        #expect(SessionUpdateQuietHours(start: -1, end: 10) == nil)
        #expect(SessionUpdateQuietHours(start: 0, end: 24 * 60) == nil)
    }
}
