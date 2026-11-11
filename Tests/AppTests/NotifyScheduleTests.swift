@testable import App
import Foundation
import Testing

@Suite("NotifySchedule")
struct NotifyScheduleTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Self.berlin
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test func nextRunLaterToday() {
        #expect(DailySchedule.nextRun(after: date("2026-11-07 06:00:00"), time: "07:00", timeZone: Self.berlin) == date("2026-11-07 07:00:00"))
    }

    @Test func nextRunTomorrowWhenPassed() {
        #expect(DailySchedule.nextRun(after: date("2026-11-07 07:00:01"), time: "07:00", timeZone: Self.berlin) == date("2026-11-08 07:00:00"))
        #expect(DailySchedule.nextRun(after: date("2026-11-07 07:00:00"), time: "07:00", timeZone: Self.berlin) == date("2026-11-08 07:00:00"))
    }

    @Test func nextRunSkipsMissingDSTHour() {
        // 2026-03-29: clocks jump from 02:00 to 03:00 in Berlin.
        let first = DailySchedule.nextRun(after: date("2026-03-29 01:00:00"), time: "02:30", timeZone: Self.berlin)
        #expect(first == date("2026-03-29 03:00:00"))
        let second = DailySchedule.nextRun(after: first, time: "02:30", timeZone: Self.berlin)
        #expect(second == date("2026-03-30 02:30:00"))
    }

    @Test func unparsableTimeFallsBackToDefault() {
        #expect(DailySchedule.nextRun(after: date("2026-11-07 06:00:00"), time: "kaputt", timeZone: Self.berlin) == date("2026-11-07 07:00:00"))
    }

    @Test func runsAtBootOnlyAfter24h() {
        let now = date("2026-11-07 12:00:00")
        #expect(DailySchedule.runsAtBoot(lastRun: nil, now: now))
        #expect(!DailySchedule.runsAtBoot(lastRun: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(DailySchedule.runsAtBoot(lastRun: now.addingTimeInterval(-25 * 3600), now: now))
    }

    @Test func parseTimes() {
        #expect(DailySchedule.parse("7:05").map { [$0.hour, $0.minute] } == [7, 5])
        #expect(DailySchedule.parse(" 07:00 ").map { [$0.hour, $0.minute] } == [7, 0])
        #expect(DailySchedule.parse("23:59").map { [$0.hour, $0.minute] } == [23, 59])
        for bad in ["24:00", "7:60", "abc", "", "7", "07:0", "-1:00", "07:00:00"] {
            #expect(DailySchedule.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func sleepReturnsEarlyOnWake() async {
        let trigger = DailyRunTrigger()
        let start = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            trigger.wake()
        }
        #expect(await trigger.sleep(until: start.addingTimeInterval(60)))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func sleepReachesDate() async {
        let trigger = DailyRunTrigger()
        #expect(await trigger.sleep(until: Date().addingTimeInterval(0.05)) == false)
    }

    @Test func wakeBeforeSleepIsKept() async {
        let trigger = DailyRunTrigger()
        trigger.wake()
        let start = Date()
        #expect(await trigger.sleep(until: start.addingTimeInterval(60)))
        #expect(Date().timeIntervalSince(start) < 5)
        // The kept wake is used up.
        #expect(await trigger.sleep(until: Date().addingTimeInterval(0.05)) == false)
    }
}
