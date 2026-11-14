@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Which titles are cached follows from what users track, so answers must not depend on other users' cache entries
/// (security audit F14): without a TMDB token only the caller's own cached titles open, and search shows episode
/// totals only for the caller's own titles.
@Suite("CacheIsolation")
struct CacheIsolationTests {
    func status(_ app: Application, _ path: String, _ headers: HTTPHeaders) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.testing().test(.GET, path, headers: headers) { res async in status = res.status }
        return status
    }

    /// bob tracks series 4242 and movie 4343; eve (no TMDB token) follows series 7777.
    func seed(_ app: Application) async throws -> User {
        let bob = try await createUser(app, "bob")
        let eve = try await createUser(app, "eve", tmdbToken: nil)
        let show = try await seedSeries(app, tmdbID: 4242, seasons: [1: 2])
        let movie = try await seedMovie(app, tmdbID: 4343)
        let own = try await seedSeries(app, tmdbID: 7777, seasons: [1: 1])
        let watches = WatchService(db: app.db)
        _ = try await watches.markEpisode(userID: bob.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
        try await watches.setRating(userID: bob.requireID(), titleID: movie.requireID(), rating: 8)
        try await watches.setFollowed(userID: eve.requireID(), titleID: own.requireID(), followed: true)
        return eve
    }

    @Test func tokenlessAPICallerSeesOnlyOwnCachedTitles() async throws {
        try await withTestApp { app in
            let eve = try await seed(app)
            let token = HTTPHeaders.bearer(try await apiToken(app, eve))
            #expect(try await status(app, "/api/v1/tv/4242", token) == .unprocessableEntity)
            #expect(try await status(app, "/api/v1/movies/4343", token) == .unprocessableEntity)
            #expect(try await status(app, "/api/v1/tv/9999", token) == .unprocessableEntity)
            #expect(try await status(app, "/api/v1/tv/7777", token) == .ok)
        }
    }

    @Test func tokenlessWebCallerSeesOnlyOwnCachedTitles() async throws {
        try await withTestApp { app in
            _ = try await seed(app)
            let session = try await login(app, "eve")
            let uncached = try await status(app, "/tv/9999", session)
            #expect(uncached != .ok)
            #expect(try await status(app, "/tv/4242", session) == uncached)
            #expect(try await status(app, "/movie/4343", session) == (try await status(app, "/movie/9998", session)))
            #expect(try await status(app, "/tv/7777", session) == .ok)
        }
    }

    @Test func searchShowsTotalsOnlyForOwnTitles() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setSearch("multi", "Probe", [
            TMDBSearchResult(id: 4242, kind: .tv, name: "Probe A", originalName: nil, year: 2020, posterPath: nil),
            TMDBSearchResult(id: 7777, kind: .tv, name: "Probe B", originalName: nil, year: 2020, posterPath: nil),
        ])
        try await withTestApp(tmdb: tmdb) { app in
            let eve = try await seed(app)
            let hits = try await SearchService(db: app.db, tmdb: tmdb).search(userID: eve.requireID(), query: "Probe")
            #expect(hits.map(\.inLibrary) == [false, true])
            #expect(hits.map(\.totalEpisodes) == [nil, 1])
            #expect(hits.map(\.watchedEpisodes) == [nil, 0])
        }
    }
}
