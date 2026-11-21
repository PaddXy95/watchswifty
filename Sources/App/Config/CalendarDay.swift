import Foundation

/// ISO calendar days (`yyyy-MM-dd`) – the app's representation of dates without time.
enum CalendarDay {
    /// A Gregorian calendar in the given time zone.
    /// - Parameter timeZone: The time zone.
    /// - Returns: The calendar.
    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// UTC, in which ISO days are parsed and shifted.
    private static let utc = TimeZone(identifier: "UTC")!

    /// The calendar day of a moment as `yyyy-MM-dd`.
    ///
    /// App code uses `AppConfig.today` instead, which tests pin.
    /// - Parameters:
    ///   - now: The moment.
    ///   - timeZone: The time zone deciding the day.
    /// - Returns: The ISO day.
    static func today(now: Date = .now, timeZone: TimeZone = .current) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: now)
        return format(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Formats date components as `yyyy-MM-dd`.
    /// - Parameters:
    ///   - year: The year.
    ///   - month: The month (1–12).
    ///   - day: The day of the month.
    /// - Returns: The ISO day.
    static func format(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses `yyyy-MM-dd` into a UTC midnight date; nil for malformed or impossible dates.
    /// - Parameter iso: The ISO day.
    /// - Returns: Midnight UTC of that day, or nil.
    static func date(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let cal = calendar(utc)
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }

    /// Whether the text is a valid ISO day.
    /// - Parameter iso: The text to check.
    /// - Returns: True for a real `yyyy-MM-dd` date.
    static func isValid(_ iso: String) -> Bool { date(iso) != nil }

    /// Whole days from `a` to `b` (positive when `b` is later).
    /// - Parameters:
    ///   - a: The start day.
    ///   - b: The end day.
    /// - Returns: The number of days, 0 when either day is malformed.
    static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = date(a), let db = date(b) else { return 0 }
        return calendar(utc).dateComponents([.day], from: da, to: db).day ?? 0
    }

    /// Adds calendar months (clamped to the month's last day) to an ISO day.
    /// - Parameters:
    ///   - months: The months to add (negative to go back).
    ///   - iso: The ISO day.
    /// - Returns: The shifted day, or `iso` unchanged when it is malformed.
    static func adding(months: Int, to iso: String) -> String {
        shifted(iso, DateComponents(month: months))
    }

    /// Adds days to an ISO day.
    /// - Parameters:
    ///   - days: The days to add (negative to go back).
    ///   - iso: The ISO day.
    /// - Returns: The shifted day, or `iso` unchanged when it is malformed.
    static func adding(days: Int, to iso: String) -> String {
        shifted(iso, DateComponents(day: days))
    }

    /// Applies date components to an ISO day in UTC.
    /// - Parameters:
    ///   - iso: The ISO day.
    ///   - components: The components to add.
    /// - Returns: The shifted day, or `iso` unchanged when it is malformed.
    private static func shifted(_ iso: String, _ components: DateComponents) -> String {
        guard let date = date(iso), let result = calendar(utc).date(byAdding: components, to: date) else { return iso }
        return today(now: result, timeZone: utc)
    }

    /// The German display form `dd.MM.yyyy` of an ISO day.
    /// - Parameter iso: The ISO day.
    /// - Returns: The display text; other input unchanged.
    static func display(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }
}
