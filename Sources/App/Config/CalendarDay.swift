import Foundation

/// ISO calendar days (`yyyy-MM-dd`) – the app's representation of dates without time.
enum CalendarDay {
    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private static let utc = TimeZone(identifier: "UTC")!

    static func today(now: Date = .now, timeZone: TimeZone = .current) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: now)
        return format(year: c.year!, month: c.month!, day: c.day!)
    }

    static func format(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses `yyyy-MM-dd` into a UTC midnight date; nil for malformed or impossible dates.
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

    static func isValid(_ iso: String) -> Bool { date(iso) != nil }

    /// Whole days from `a` to `b` (positive when `b` is later).
    static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = date(a), let db = date(b) else { return 0 }
        return calendar(utc).dateComponents([.day], from: da, to: db).day ?? 0
    }

    static func display(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }
}
