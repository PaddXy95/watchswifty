@testable import App
import NIOConcurrencyHelpers

/// GitHub stand-in: returns `release` or throws `failure`; counts calls.
final class FakeReleaseFetcher: ReleaseFetcher, @unchecked Sendable {
    private struct State {
        var release = LatestRelease(version: "0.1.3", url: "https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3")
        var failure: ReleaseCheckError?
        var calls = 0
    }

    private let state = NIOLockedValueBox(State())

    var calls: Int { state.withLockedValue { $0.calls } }
    var failure: ReleaseCheckError? {
        get { state.withLockedValue { $0.failure } }
        set { state.withLockedValue { $0.failure = newValue } }
    }

    func latestRelease() async throws -> LatestRelease {
        let (release, failure) = state.withLockedValue { s -> (LatestRelease, ReleaseCheckError?) in
            s.calls += 1
            return (s.release, s.failure)
        }
        if let failure { throw failure }
        return release
    }
}
