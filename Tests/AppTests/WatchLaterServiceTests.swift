@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("WatchLaterService")
struct WatchLaterServiceTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func service(_ app: Application) -> WatchLaterService { WatchLaterService(db: app.db) }

    func entries(_ app: Application) async throws -> [WatchLaterEntry] {
        try await WatchLaterEntry.query(on: app.db).all()
    }

    /// Puts an existing title on pat's list directly (added 2026-11-07).
    func listed(_ app: Application, _ user: User, _ title: Title) async throws {
        try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(), addedAt: start, addedOn: "2026-11-07",
                                  baselined: true).save(on: app.db)
    }

    @Test func addCreatesTitleAndEntryAndFetches() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil))
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            try await UserStreamingService(userID: user.requireID(), providerID: 8).save(on: app.db)
            let title = try await service(app).add(userID: user.requireID(), kind: .movie, tmdbID: 603, catalog: CatalogService(db: app.db, tmdb: tmdb),
                                                   today: "2026-11-07", now: start, logger: app.logger)
            #expect(title.name == "Matrix")
            let list = try await entries(app)
            #expect(list.count == 1)
            #expect(list.first?.addedOn == "2026-11-07")
            #expect(list.first?.baselined == true)   // the immediate fetch recorded the present offers
            #expect(try await TitleAvailability.query(on: app.db).count() == 1)
            #expect(tmdb.calls.contains("watch_providers:movie:603"))
            _ = try await service(app).add(userID: user.requireID(), kind: .movie, tmdbID: 603, catalog: CatalogService(db: app.db, tmdb: tmdb),
                                           today: "2026-11-08", now: start, logger: app.logger)
            #expect(try await entries(app).count == 1)
            #expect(try await AvailabilityNotice.query(on: app.db).first()?.noticeState == .baseline)
        }
    }

    @Test func addSurvivesTMDBFailure() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil))
        tmdb.fail("watch_providers:movie:603", with: .rateLimited)
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await service(app).add(userID: user.requireID(), kind: .movie, tmdbID: 603, catalog: CatalogService(db: app.db, tmdb: tmdb),
                                           today: "2026-11-07", now: start, logger: app.logger)
            #expect(try await entries(app).first?.baselined == false)
            #expect(try await TitleAvailability.query(on: app.db).count() == 0)
        }
    }

    @Test func addUnknownTitleThrows() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            await #expect(throws: (any Error).self) {
                _ = try await service(app).add(userID: user.requireID(), kind: .movie, tmdbID: 999, catalog: CatalogService(db: app.db, tmdb: tmdb),
                                               today: "2026-11-07", now: start, logger: app.logger)
            }
            #expect(try await entries(app).isEmpty)
        }
    }

    enum Mark: CaseIterable { case movie, movieOldDate, episode, season, series, upTo }

    @Test(arguments: Mark.allCases) func manualWatchRemovesEntry(_ mark: Mark) async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let userID = try user.requireID()
            let watches = WatchService(db: app.db, today: { "2026-11-07" })
            switch mark {
            case .movie, .movieOldDate:
                let movie = try await seedMovie(app, tmdbID: 603)
                try await listed(app, user, movie)
                _ = try await watches.markMovie(userID: userID, titleID: movie.requireID(), day: mark == .movie ? nil : "2020-01-01",
                                                service: nil)
            case .episode, .season, .series, .upTo:
                let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
                try await listed(app, user, series)
                let first = try await episode(app, series, 1, 1)
                switch mark {
                case .episode: _ = try await watches.markEpisode(userID: userID, episodeID: first.requireID(), day: nil, service: nil)
                case .season: _ = try await watches.markSeason(userID: userID, titleID: series.requireID(), season: 1, service: nil)
                case .series: _ = try await watches.markSeries(userID: userID, titleID: series.requireID(), service: nil)
                default: _ = try await watches.markUpTo(userID: userID, episodeID: first.requireID(), service: nil)
                }
            }
            #expect(try await entries(app).isEmpty)
        }
    }

    @Test func importedOldWatchKeepsEntry() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await listed(app, user, movie)
            let watches = WatchService(db: app.db, today: { "2026-11-07" })
            _ = try await watches.recordImportedWatch(userID: user.requireID(), titleID: movie.requireID(), episodeID: nil, day: "2020-01-01")
            #expect(try await entries(app).count == 1)
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 1])
            try await listed(app, user, series)
            _ = try await watches.recordImportedWatch(userID: user.requireID(), titleID: series.requireID(),
                                                      episodeID: try await episode(app, series, 1, 1).requireID(), day: "2026-11-07")
            #expect(try await entries(app).count == 1)   // the series entry is gone, the movie entry stays
            #expect(try await entries(app).first?.$title.id == movie.id)
        }
    }

    @Test func otherUsersWatchDoesNotRemove() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let other = try await createUser(app, "sepp")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await listed(app, user, movie)
            _ = try await WatchService(db: app.db, today: { "2026-11-07" }).markMovie(userID: other.requireID(),
                                                                                    titleID: movie.requireID(), day: nil, service: nil)
            #expect(try await entries(app).count == 1)
        }
    }

    @Test func removeDeletesNotices() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await listed(app, user, movie)
            try await AvailabilityNotice(userID: user.requireID(), titleID: movie.requireID(), providerID: 8, noticedAt: start,
                                         state: .sent).save(on: app.db)
            try await service(app).remove(userID: user.requireID(), titleID: movie.requireID())
            #expect(try await entries(app).isEmpty)
            #expect(try await AvailabilityNotice.query(on: app.db).count() == 0)
            #expect(try await !service(app).contains(userID: user.requireID(), titleID: movie.requireID()))
        }
    }

    @Test func pageGroupsAndSorts() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 1, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        tmdb.setWatchProviders(kind: .tv, id: 2, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        tmdb.setWatchProviders(kind: .movie, id: 3, TMDBWatchProviders(offers: ["DE": [offer(337, "Disney Plus", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            try await UserStreamingService(userID: user.requireID(), providerID: 8).save(on: app.db)
            let a = try await seedMovie(app, tmdbID: 1, name: "A")
            let b = try await seedSeries(app, tmdbID: 2, name: "B", seasons: [1: 1])
            let c = try await seedMovie(app, tmdbID: 3, name: "C")
            let d = try await seedMovie(app, tmdbID: 4, name: "D")
            for (offset, title) in [a, b, c, d].enumerated() {
                try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(),
                                          addedAt: start.addingTimeInterval(Double(offset) * 60), addedOn: "2026-11-07", baselined: true)
                    .save(on: app.db)
            }
            for title in [a, b, c] { try await AvailabilityService(db: app.db).refresh(title, tmdb: tmdb, now: start) }

            let page = try await service(app).page(user: user, filter: "all", now: start)
            #expect(page.hasServices)
            #expect(page.atMyServices.map(\.title.name) == ["B", "A"])     // newest first
            #expect(page.others.map(\.title.name) == ["D", "C"])
            #expect(page.others.first?.groups == nil)                       // D never fetched
            #expect(page.oldestFetch == start)
            #expect(try await service(app).page(user: user, filter: "tv", now: start).atMyServices.map(\.title.name) == ["B"])
        }
    }
}
