@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Shared setup for the TMDB reload tests (worker, Konto and API).
enum RefreshSeed {
    static func series(_ id: Int) -> TMDBSeries {
        TMDBSeries(id: id, name: "Serie \(id)", originalName: nil, year: 2020, posterPath: nil, status: "Ended",
                   seasonNumbers: [1], genreIDs: [18])
    }

    static func movie(_ id: Int) -> TMDBMovie {
        TMDBMovie(id: id, name: "Film \(id)", originalName: nil, year: 2020, posterPath: nil, runtime: 100, genreIDs: [18])
    }

    static func watch(_ app: Application, _ user: User, _ title: Title) async throws {
        try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: nil, watchedOn: "2026-01-01",
                        service: nil, origin: .manual).save(on: app.db)
    }

    static func entry(_ app: Application, _ user: User, _ title: Title, hidden: Bool = false, followed: Bool = false) async throws {
        let entry = UserTitle(userID: try user.requireID(), titleID: try title.requireID())
        entry.hidden = hidden
        entry.followed = followed
        try await entry.save(on: app.db)
    }
}

@Suite("LibraryRefresh")
struct LibraryRefreshTests {
    @Test func titlesCoverOwnSeriesAndMoviesOnly() async throws {
        try await withTestApp { app in
            let a = try await createUser(app, "anna")
            let b = try await createUser(app, "ben")
            let watched = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], genres: nil)
            let hidden = try await seedMovie(app, tmdbID: 2, genres: nil)
            let followed = try await seedSeries(app, tmdbID: 3, seasons: [1: 1], genres: nil)
            let complete = try await seedSeries(app, tmdbID: 4, seasons: [1: 1], runtime: 30, genres: "drama")
            let foreign = try await seedSeries(app, tmdbID: 5, seasons: [1: 1], genres: nil)
            try await RefreshSeed.watch(app, a, watched)
            try await RefreshSeed.entry(app, a, hidden, hidden: true)
            try await RefreshSeed.entry(app, a, followed, followed: true)
            try await RefreshSeed.watch(app, a, complete)
            try await RefreshSeed.watch(app, b, foreign)

            let titles = try await libraryRefreshTitles(userID: a.requireID(), on: app.db)
            #expect(titles.map(\.tmdbID) == [1, 2, 3, 4])   // 1–3 lack genres, so they come first
        }
    }

    @Test func refreshLoadsEveryTitleAndReportsProgress() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(RefreshSeed.series(1), episodes: [1: ["Pilot"]])
        tmdb.addMovie(RefreshSeed.movie(2))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            let series = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], genres: nil)
            let movie = try await seedMovie(app, tmdbID: 2, genres: nil)
            try await RefreshSeed.watch(app, user, series)
            try await RefreshSeed.watch(app, user, movie)

            let userID = try user.requireID()
            let started = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            #expect(started.running && started.total == 2)
            await app.libraryRefresh.wait(userID: userID)

            let state = await app.libraryRefresh.state(userID: userID)
            #expect(!state.running)
            #expect(state.done == 2 && state.total == 2 && state.failed == 0 && state.refreshed == 2)
            #expect(state.finishedAt != nil && state.error == nil)
            #expect(tmdb.calls.contains("series:1") && tmdb.calls.contains("movie:2"))
            let reloaded = try await Title.query(on: app.db).all()
            #expect(reloaded.allSatisfy { $0.genres != nil })
        }
    }

    @Test func emptyLibraryFinishesAtOnce() async throws {
        try await withTestApp { app in
            let userID = try await createUser(app, "anna").requireID()
            _ = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            await app.libraryRefresh.wait(userID: userID)
            let state = await app.libraryRefresh.state(userID: userID)
            #expect(state.total == 0 && !state.running && state.finishedAt != nil)
        }
    }

    @Test func failedTitleIsCountedAndRunContinues() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(RefreshSeed.series(1), episodes: [1: ["Pilot"]])   // movie 2 unknown to TMDB → notFound
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedSeries(app, tmdbID: 1, seasons: [1: 1]))
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 2))
            let userID = try user.requireID()
            _ = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            await app.libraryRefresh.wait(userID: userID)
            let state = await app.libraryRefresh.state(userID: userID)
            #expect(state.done == 2 && state.failed == 1 && state.error == nil)
        }
    }

    @Test func invalidTokenStopsTheRun() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .unauthorized
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedSeries(app, tmdbID: 1, seasons: [1: 1]))
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 2))
            let userID = try user.requireID()
            _ = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            await app.libraryRefresh.wait(userID: userID)
            let state = await app.libraryRefresh.state(userID: userID)
            #expect(!state.running && state.done == 0)
            #expect(state.error == TMDBError.unauthorized.description)
            #expect(tmdb.calls.count == 1)
        }
    }

    @Test func secondStartWhileRunningKeepsOneRun() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(RefreshSeed.movie(1))
        tmdb.addMovie(RefreshSeed.movie(2))
        tmdb.delay = .seconds(30)   // the first run cannot finish before the second start, however slow the machine
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 1))
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 2))
            let userID = try user.requireID()
            _ = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            let second = try await app.libraryRefresh.start(userID: userID, token: "test-token")
            #expect(second.running)
            await app.libraryRefresh.cancel(userID: userID)
            #expect(tmdb.calls.count <= 1)   // one run asked for its first title at most; a second run would add another
        }
    }
}
