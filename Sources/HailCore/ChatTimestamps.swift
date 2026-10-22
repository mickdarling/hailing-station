public import Foundation

/// When each station chat entry happened, shown the way Messages does (#766): a centred header where a new group
/// starts, and each entry's own time on demand. Uses the entry's `date`, the moment it joined the log, in the
/// device's time zone and 12- or 24-hour setting.
public enum ChatTimestamps {
    /// A pause this long between two entries starts a new group, as a new day does.
    public static let groupGap: TimeInterval = 15 * 60

    /// The indices of `dates` that start a group: the first, any after a gap of `groupGap` or more, any on a new day.
    public static func groupStarts(_ dates: [Date], calendar: Calendar = .autoupdatingCurrent) -> Set<Int> {
        var starts: Set<Int> = []
        for (index, date) in dates.enumerated() {
            guard index > 0 else { starts.insert(index); continue }
            let previous = dates[index - 1]
            if date.timeIntervalSince(previous) >= groupGap || !calendar.isDate(date, inSameDayAs: previous) {
                starts.insert(index)
            }
        }
        return starts
    }

    /// A group's header: "Today 9:41 PM", "Yesterday 10:02 AM", the weekday within the past week ("Tuesday 9:41 PM"),
    /// the date this year ("Mon, Oct 5 at 9:41 PM"), else with its year ("Oct 5, 2025 at 9:41 PM").
    public static func header(
        for date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let clock = time(date, calendar: calendar, locale: locale)
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch daysAgo {
        case ...0: return "Today \(clock)" // A clock a little ahead of the Mac's still reads as today.
        case 1: return "Yesterday \(clock)"
        case 2...6: return "\(date.formatted(style.weekday(.wide))) \(clock)"
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let dated = sameYear ? style.weekday(.abbreviated).month(.abbreviated).day()
                : style.month(.abbreviated).day().year()
            return "\(date.formatted(dated)) at \(clock)"
        }
    }

    /// An entry's own time, "9:41 PM" or "21:41" by the device's setting.
    public static func time(
        _ date: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
    }
}
