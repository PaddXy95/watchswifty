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

    @Test func refreshStoresGenres() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1, name: "Serie", originalName: nil, year: nil, posterPath: nil, status: nil, seasonNumbers: [],
                                  genreIDs: [10759, 80]), episodes: [:])
        tmdb.addMovie(TMDBMovie(id: 2, name: "Film", originalName: nil, year: nil, posterPath: nil))
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let series = try await catalog.title(kind: .tv, tmdbID: 1)
            let movie = try await catalog.title(kind: .movie, tmdbID: 2)
            #expect(series.genres == "action,adventure,crime")
            #expect(movie.genres == "")
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

    @Test func refreshStampsFirstAndLastSeen() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1399)
            // Rows that existed before this version have no first-seen time.
            let old = try await catalog.episodes(of: title.requireID())[0]
            old.firstSeenAt = nil
            try await old.save(on: app.db)
            tmdb.addSeries(Self.series, episodes: [1: ["Eins", "Zwei"], 2: ["Drei", "Vier", "Fünf"]])
            let t1 = Date(timeIntervalSince1970: 1_800_000_000)
            try await catalog.refresh(title, now: t1)
            let after = try await catalog.episodes(of: title.requireID())
            let e1 = after[0], e5 = try #require(after.last)
            #expect(e5.firstSeenAt == t1)
            #expect(e1.firstSeenAt == nil)
            #expect(after.allSatisfy { $0.lastSeenAt == t1 })
            #expect(e1.isCurrent(titleRefreshedAt: title.refreshedAt))
        }
    }

    @Test func episodeMissingFromRefreshBecomesStale() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1399)
            tmdb.addSeries(Self.series, episodes: [1: ["Eins"], 2: ["Drei", "Vier"]])
            let t2 = Date(timeIntervalSince1970: 1_800_000_000)
            try await catalog.refresh(title, now: t2)
            let after = try await catalog.episodes(of: title.requireID())
            let e1 = after[0], e2 = after[1]
            #expect(e2.number == 2 && e2.season == 1)
            #expect(e2.lastSeenAt != t2)
            #expect(!e2.isCurrent(titleRefreshedAt: t2))
            #expect(e1.isCurrent(titleRefreshedAt: t2))
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

@Suite("CatalogOverview")
struct CatalogOverviewTests {
    @Test func refreshStoresOverviewOrEmpty() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1, name: "Mit Text", originalName: nil, year: nil, posterPath: nil, status: nil,
                                  seasonNumbers: [1], overview: "Worum es geht."), episodes: [1: ["A"]])
        tmdb.addSeries(TMDBSeries(id: 2, name: "Ohne Text", originalName: nil, year: nil, posterPath: nil, status: nil,
                                  seasonNumbers: [1]), episodes: [1: ["A"]])
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let withText = try await catalog.title(kind: .tv, tmdbID: 1)
            let withoutText = try await catalog.title(kind: .tv, tmdbID: 2)
            #expect(withText.overview == "Worum es geht.")
            #expect(withoutText.overview == "")
        }
    }
}

@Suite("CatalogIMDb")
struct CatalogIMDbTests {
    @Test func refreshStoresIMDbID() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1399, name: "Game of Thrones", originalName: nil, year: nil, posterPath: nil, status: nil,
                                  seasonNumbers: [1]), episodes: [1: ["A"]])
        tmdb.setIMDbID(seriesID: 1399, "tt0944947")
        tmdb.addSeries(TMDBSeries(id: 2, name: "Ohne", originalName: nil, year: nil, posterPath: nil, status: nil,
                                  seasonNumbers: [1]), episodes: [1: ["A"]])
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: nil, posterPath: nil, imdbID: "tt0133093"))
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let got = try await catalog.title(kind: .tv, tmdbID: 1399)
            let none = try await catalog.title(kind: .tv, tmdbID: 2)
            let movie = try await catalog.title(kind: .movie, tmdbID: 603)
            #expect(got.imdbID == "tt0944947")
            #expect(none.imdbID == "")
            #expect(movie.imdbID == "tt0133093")
        }
    }
}

@Suite("CatalogEpisodeOverview")
struct CatalogEpisodeOverviewTests {
    @Test func refreshStoresEpisodeOverview() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1, name: "S", originalName: nil, year: nil, posterPath: nil, status: nil, seasonNumbers: [1]), episodes: [:])
        tmdb.setSeason(seriesID: 1, number: 1, [
            TMDBEpisode(id: 11, season: 1, number: 1, name: "Pilot", airDate: "2020-01-01", overview: "Es beginnt."),
            TMDBEpisode(id: 12, season: 1, number: 2, name: "Zwei", airDate: "2020-01-08"),
        ])
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let title = try await catalog.title(kind: .tv, tmdbID: 1)
            let episodes = try await catalog.episodes(of: title.requireID())
            #expect(episodes.map(\.overview) == ["Es beginnt.", ""])
        }
    }
}
