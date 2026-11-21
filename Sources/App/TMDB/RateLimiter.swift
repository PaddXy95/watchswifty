import Foundation

/// Spaces calls at least `minInterval` apart (20 req/s with the default).
/// One instance is shared by all users' TMDB clients, so the whole server stays within one TMDB budget.
actor RateLimiter {
    /// Minimum spacing between two calls.
    private let minInterval: Duration
    /// Earliest instant the next call may start.
    private var next: ContinuousClock.Instant = .now

    /// Creates a limiter.
    /// - Parameter minInterval: Minimum spacing between calls (50 ms, i.e. 20 requests per second, by default).
    init(minInterval: Duration = .milliseconds(50)) {
        self.minInterval = minInterval
    }

    /// Reserves the next free slot and sleeps until it arrives.
    /// - Throws: `CancellationError` when the task is cancelled while waiting.
    func acquire() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot + minInterval
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }
}
