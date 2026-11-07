import Foundation

/// Spaces calls at least `minInterval` apart (20 req/s with the default).
actor RateLimiter {
    private let minInterval: Duration
    private var next: ContinuousClock.Instant = .now

    init(minInterval: Duration = .milliseconds(50)) {
        self.minInterval = minInterval
    }

    func acquire() async throws {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot + minInterval
        if slot > now {
            try await Task.sleep(until: slot, clock: .continuous)
        }
    }
}
