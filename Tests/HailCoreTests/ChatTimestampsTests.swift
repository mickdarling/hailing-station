import Foundation
import Testing
@testable import HailCore

/// #766: the station chat's Messages-style timestamps, on a fixed calendar, time zone and locale.
@Suite struct ChatTimestampsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt // a missing zone fails every expectation
        return calendar
    }()
    private static let us = Locale(identifier: "en_US"), uk = Locale(identifier: "en_GB")

    /// 2026-10-21 (a Wednesday) at `hour`:`minute` New York time, shifted by `days`.
    private static func date(days: Int = 0, _ hour: Int, _ minute: Int, year: Int = 2026) -> Date {
        let base = calendar.date(from: DateComponents(year: year, month: 10, day: 21, hour: hour, minute: minute))
        return calendar.date(byAdding: .day, value: days, to: base ?? .distantPast) ?? .distantPast
    }

    /// Foundation puts a narrow no-break space before AM and PM; the tests read it as a space.
    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    private static func header(_ date: Date, now: Date = date(21, 50), locale: Locale = us) -> String {
        plain(ChatTimestamps.header(for: date, now: now, calendar: calendar, locale: locale))
    }

    @Test func theFirstEntryAGapOfFifteenMinutesAndANewDayEachStartAGroup() {
        let dates = [
            Self.date(9, 0), Self.date(9, 14), Self.date(9, 28), // under 15 minutes apart: one group
            Self.date(9, 43), // exactly 15 minutes after the last
            Self.date(23, 50), Self.date(days: 1, 0, 1) // 11 minutes apart, across midnight
        ]
        #expect(ChatTimestamps.groupStarts(dates, calendar: Self.calendar) == [0, 3, 4, 5])
        #expect(ChatTimestamps.groupStarts([], calendar: Self.calendar).isEmpty)
    }

    @Test func todayAndYesterdayAreNamed() {
        #expect(Self.header(Self.date(21, 41)) == "Today 9:41 PM")
        #expect(Self.header(Self.date(days: -1, 10, 2)) == "Yesterday 10:02 AM")
        // Just after midnight, an entry from late the evening before is yesterday's.
        #expect(Self.header(Self.date(23, 59), now: Self.date(days: 1, 0, 5)) == "Yesterday 11:59 PM")
    }

    @Test func thePastWeekShowsTheWeekdayAndOlderShowsTheDate() {
        #expect(Self.header(Self.date(days: -2, 9, 41)) == "Monday 9:41 AM")
        #expect(Self.header(Self.date(days: -6, 9, 41)) == "Thursday 9:41 AM")
        #expect(Self.header(Self.date(days: -7, 9, 41)) == "Wed, Oct 14 at 9:41 AM")
        #expect(Self.header(Self.date(9, 41, year: 2025)) == "Oct 21, 2025 at 9:41 AM")
    }

    @Test func aClockAheadOfNowStillReadsAsToday() {
        #expect(Self.header(Self.date(days: 1, 8, 0)) == "Today 8:00 AM")
    }

    @Test func theTimeFollowsTheLocalesClock() {
        let date = Self.date(21, 41)
        #expect(Self.plain(ChatTimestamps.time(date, calendar: Self.calendar, locale: Self.us)) == "9:41 PM")
        #expect(ChatTimestamps.time(date, calendar: Self.calendar, locale: Self.uk) == "21:41")
        #expect(Self.header(date, locale: Self.uk) == "Today 21:41")
    }

    @Test func theTimeIsTheCalendarsTimeZone() throws {
        var london = Self.calendar
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        #expect(Self.plain(ChatTimestamps.time(Self.date(21, 41), calendar: london, locale: Self.us)) == "2:41 AM")
    }
}
