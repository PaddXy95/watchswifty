import Foundation
import NIOConcurrencyHelpers

/// When the daily pass (TMDB refresh, cleanup, notifications) runs: every day at the admin's time, server time zone.
enum DailySchedule {
    static let defaultTime = "07:00"

    /// `H:MM` or `HH:MM` (trimmed), hour 0–23, minute 0–59.
    static func parse(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// `HH:MM` zero-padded, nil when unparsable.
    static func normalized(_ raw: String) -> String? {
        parse(raw).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
    }

    /// First moment strictly after `now` with the given wall-clock time; on a DST day without that time, the next
    /// existing moment, and only once when the time occurs twice.
    static func nextRun(after now: Date, time: String, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let (hour, minute) = parse(time) ?? parse(defaultTime)!
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? now.addingTimeInterval(86_400)
    }

    /// Latest moment at or before `now` with the given wall-clock time (on a DST day without it, the next existing one).
    static func previousRun(atOrBefore now: Date, time: String, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let (hour, minute) = parse(time) ?? parse(defaultTime)!
        for daysBack in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            else { continue }
            if candidate <= now { return candidate }
        }
        return now.addingTimeInterval(-86_400)
    }

    /// After a start the pass runs at once (after a short delay) when the set time passed since the last complete
    /// pass – a server that was off at that time catches up, a plain restart does not run it again.
    static func runsAtBoot(lastRun: Date?, now: Date, time: String, timeZone: TimeZone) -> Bool {
        guard let lastRun else { return true }
        return lastRun < previousRun(atOrBefore: now, time: time, timeZone: timeZone)
    }
}

/// Lets the daily loop sleep until its next run and be woken early when the admin changes the time.
final class DailyRunTrigger: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
        var timer: Task<Void, Never>?
    }

    private struct State {
        /// A wake while nobody sleeps is kept for the next sleep (a save during a pass is not lost).
        var pending = false
        var waiter: Waiter?
    }

    private let state = NIOLockedValueBox(State())

    func wake() {
        let waiter = state.withLockedValue { state -> Waiter? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: true)
    }

    /// True when woken before `date`, false when `date` was reached or the task was cancelled.
    func sleep(until date: Date) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let woken = state.withLockedValue { state -> Bool in
                    if state.pending {
                        state.pending = false
                        return true
                    }
                    state.waiter = Waiter(id: id, continuation: continuation)
                    return false
                }
                if woken {
                    continuation.resume(returning: true)
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                    self?.finish(id: id)
                }
                state.withLockedValue { state in
                    if state.waiter?.id == id { state.waiter?.timer = timer } else { timer.cancel() }
                }
                if Task.isCancelled { finish(id: id) }
            }
        } onCancel: {
            finish(id: id)
        }
    }

    private func finish(id: UUID) {
        let waiter = state.withLockedValue { state -> Waiter? in
            guard state.waiter?.id == id else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: false)
    }
}
