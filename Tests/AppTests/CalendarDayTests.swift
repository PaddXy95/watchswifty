@testable import App
import Foundation
import Testing

@Suite("CalendarDay")
struct CalendarDayTests {
    @Test func display() {
        #expect(CalendarDay.display("2026-11-07") == "07.11.2026")
    }

    @Test func daysBetween() {
        #expect(CalendarDay.daysBetween("2026-11-06", "2026-11-07") == 1)
        #expect(CalendarDay.daysBetween("2026-11-07", "2026-11-06") == -1)
        #expect(CalendarDay.daysBetween("2025-12-31", "2026-01-01") == 1)
    }

    @Test func isValid() {
        #expect(CalendarDay.isValid("2026-11-07"))
        #expect(CalendarDay.isValid("2026-02-30") == false)
        #expect(CalendarDay.isValid("7.11.2026") == false)
    }

    @Test func todayUsesTimeZone() {
        let instant = Date(timeIntervalSince1970: 1_793_833_200) // 2026-11-04T23:00:00Z
        #expect(CalendarDay.today(now: instant, timeZone: TimeZone(identifier: "Europe/Berlin")!) == "2026-11-05")
        #expect(CalendarDay.today(now: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-11-04")
    }

    @Test func addingMonthsAndDays() {
        #expect(CalendarDay.adding(months: -3, to: "2026-11-07") == "2026-08-07")
        #expect(CalendarDay.adding(months: -3, to: "2026-05-31") == "2026-02-28")
        #expect(CalendarDay.adding(days: -1, to: "2026-08-07") == "2026-08-06")
    }

    @Test func testingConfigPinsToday() {
        #expect(AppConfig.testing.today() == "2026-11-07")
    }
}
