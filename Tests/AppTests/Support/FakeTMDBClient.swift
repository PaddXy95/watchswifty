@testable import App
import NIOConcurrencyHelpers
import Vapor

/// In-memory TMDB used by tests. Every call is logged in `calls`.
final class FakeTMDBClient: TMDBClient, @unchecked Sendable {
    struct State {
        var searchResults: [String: [TMDBSearchResult]] = [:]   // "tv:query", "movie:query", "multi:query"
        var seriesByID: [Int: TMDBSeries] = [:]
        var seasons: [String: [TMDBEpisode]] = [:]              // "seriesID/season"
        var moviesByID: [Int: TMDBMovie] = [:]
        var failure: TMDBError?
        var genericFailure = false
        var calls: [String] = []
    }

    let state = NIOLockedValueBox(State())

    var calls: [String] { state.withLockedValue { $0.calls } }
    var failure: TMDBError? {
        get { state.withLockedValue { $0.failure } }
        set { state.withLockedValue { $0.failure = newValue } }
    }

    struct Boom: Error {}

    /// Makes every call throw a non-TMDB error (e.g. a database or decoding problem).
    var genericFailure: Bool {
        get { state.withLockedValue { $0.genericFailure } }
        set { state.withLockedValue { $0.genericFailure = newValue } }
    }

    func setSearch(_ kind: String, _ query: String, _ results: [TMDBSearchResult]) {
        state.withLockedValue { $0.searchResults["\(kind):\(query)"] = results }
    }

    /// Registers a series with seasons; `episodes[n]` are the episode names of season n.
    func addSeries(_ series: TMDBSeries, episodes: [Int: [String]], airDate: String = "2020-01-01") {
        state.withLockedValue { s in
            s.seriesByID[series.id] = series
            for (season, names) in episodes {
                s.seasons["\(series.id)/\(season)"] = names.enumerated().map { index, name in
                    TMDBEpisode(id: series.id * 10_000 + season * 100 + index + 1, season: season, number: index + 1, name: name, airDate: airDate)
                }
            }
        }
    }

    func setSeason(seriesID: Int, number: Int, _ episodes: [TMDBEpisode]) {
        state.withLockedValue { $0.seasons["\(seriesID)/\(number)"] = episodes }
    }

    func addMovie(_ movie: TMDBMovie) {
        state.withLockedValue { $0.moviesByID[movie.id] = movie }
    }

    private func record(_ call: String) throws {
        let (failure, generic) = state.withLockedValue { s -> (TMDBError?, Bool) in
            s.calls.append(call)
            return (s.failure, s.genericFailure)
        }
        if generic { throw Boom() }
        if let failure { throw failure }
    }

    func validate() async throws {
        try record("validate")
    }

    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult] {
        try record("search:\(kind.rawValue):\(query)")
        return state.withLockedValue { $0.searchResults["\(kind.rawValue):\(query)"] ?? [] }
    }

    func searchMulti(_ query: String) async throws -> [TMDBSearchResult] {
        try record("multi:\(query)")
        return state.withLockedValue { $0.searchResults["multi:\(query)"] ?? [] }
    }

    func series(id: Int) async throws -> TMDBSeries {
        try record("series:\(id)")
        guard let series = state.withLockedValue({ $0.seriesByID[id] }) else { throw TMDBError.notFound }
        return series
    }

    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode] {
        try record("season:\(seriesID)/\(number)")
        guard let episodes = state.withLockedValue({ $0.seasons["\(seriesID)/\(number)"] }) else { throw TMDBError.notFound }
        return episodes
    }

    func movie(id: Int) async throws -> TMDBMovie {
        try record("movie:\(id)")
        guard let movie = state.withLockedValue({ $0.moviesByID[id] }) else { throw TMDBError.notFound }
        return movie
    }
}
