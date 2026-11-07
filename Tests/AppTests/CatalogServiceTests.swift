@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("CatalogService")
struct CatalogServiceTests {
    static let series = TMDBSeries(id: 1399, name: "Testserie", originalName: "Test Series", year: 2011, posterPath: "/t.jpg",
                                   status: "Returning Series", seasonNumbers: [1, 2])

    func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(Self.series, episodes: [1: ["Eins", "Zwei"], 2: ["Drei", "Vier"]])
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: "The Matrix", year: 1999, posterPath: "/m.jpg"))
        return tmdb
    }

    @Test func newSeriesLoadsAllEpisodes() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1399)
            #expect(title.name == "Testserie")
            #expect(title.titleKind == .tv)
            #expect(title.tmdbStatus == "Returning Series")
            #expect(title.refreshedAt != nil)
            let episodes = try await catalog.episodes(of: title.requireID())
            #expect(episodes.map { "\($0.season)x\($0.number) \($0.name)" } == ["1x1 Eins", "1x2 Zwei", "2x1 Drei", "2x2 Vier"])
            #expect(tmdb.calls.filter { $0 == "series:1399" }.count == 1)
            #expect(tmdb.calls.filter { $0 == "season:1399/1" }.count == 1)
            #expect(tmdb.calls.filter { $0 == "season:1399/2" }.count == 1)
        }
    }

    @Test func cachedTitleMakesNoCalls() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let first = try await catalog.title(kind: .tv, tmdbID: 1399)
            let callsBefore = tmdb.calls.count
            let second = try await catalog.title(kind: .tv, tmdbID: 1399)
            #expect(tmdb.calls.count == callsBefore)
            #expect(first.id == second.id)
        }
    }

    @Test func refreshUpsertsKeepingIDs() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1399)
            let before = try await catalog.episodes(of: title.requireID())
            tmdb.addSeries(Self.series, episodes: [1: ["Eins (neu)", "Zwei"], 2: ["Drei", "Vier", "Fünf"]])
            try await catalog.refresh(title)
            let after = try await catalog.episodes(of: title.requireID())
            #expect(after.count == 5)
            #expect(after[0].id == before[0].id)
            #expect(after[0].name == "Eins (neu)")
            #expect(after.last?.name == "Fünf")
        }
    }

    @Test func refreshIfStaleRespectsAge() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1399)
            let callsBefore = tmdb.calls.count
            try await catalog.refreshIfStale(title)
            #expect(tmdb.calls.count == callsBefore)
            try await catalog.refreshIfStale(title, now: Date().addingTimeInterval(8 * 86_400))
            #expect(tmdb.calls.count > callsBefore)
        }
    }

    @Test func movieTitle() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let movie = try await catalog.title(kind: .movie, tmdbID: 603)
            #expect(movie.titleKind == .movie)
            #expect(movie.name == "Matrix")
            #expect(movie.year == 1999)
            let episodes = try await catalog.episodes(of: movie.requireID())
            #expect(episodes.isEmpty)
        }
    }

    @Test func unknownIDPropagatesNotFound() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            await #expect(throws: TMDBError.notFound) { _ = try await catalog.title(kind: .tv, tmdbID: 42) }
        }
    }
}
