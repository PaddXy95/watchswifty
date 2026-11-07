@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("WatchService")
struct WatchServiceTests {
    static let today = "2026-11-07"

    func service(_ app: Application) -> WatchService {
        WatchService(db: app.db, today: { Self.today })
    }

    func watches(_ app: Application, user: User) async throws -> [Watch] {
        try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
    }

    @Test func markEpisodeDefaultsToToday() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let e1 = try await episode(app, show, 1, 1)
            let watch = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: nil, service: nil)
            #expect(watch.watchedOn == Self.today)
            #expect(watch.watchOrigin == .manual)
            #expect(watch.streamingService == nil)
            #expect(watch.$title.id == show.id)
        }
    }

    @Test func doubleMarkCreatesOneWatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let e1 = try await episode(app, show, 1, 1)
            let a = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: nil, service: .netflix)
            let b = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: nil, service: .netflix)
            #expect(a.id == b.id)
            let all = try await watches(app, user: user)
            #expect(all.count == 1)
        }
    }

    @Test func rewatchAddsSecondWatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let e1 = try await episode(app, show, 1, 1)
            _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: "2026-01-01", service: nil)
            _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: nil, service: nil, rewatch: true)
            let all = try await watches(app, user: user)
            #expect(all.count == 2)
        }
    }

    @Test func invalidAndFutureDatesRejected() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let e1 = try await episode(app, show, 1, 1)
            await #expect(throws: TrackingError.futureDate) {
                _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: "2026-11-08", service: nil)
            }
            await #expect(throws: TrackingError.invalidDate) {
                _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: "2026-02-30", service: nil)
            }
        }
    }

    @Test func unairedRejected() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], unaired: ["1x1"], noAirDate: ["1x2"])
            for number in [1, 2] {
                let e = try await episode(app, show, 1, number)
                await #expect(throws: TrackingError.notAired) {
                    _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: e.requireID(), day: nil, service: nil)
                }
            }
        }
    }

    @Test func markUnhidesSeries() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await service(app).setHidden(userID: user.requireID(), titleID: show.requireID(), hidden: true)
            _ = try await service(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            let entry = try await service(app).userTitle(userID: user.requireID(), titleID: show.requireID())
            #expect(entry.hidden == false)
        }
    }

    @Test func unmarkRemovesAllWatchesOfEpisode() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let e1 = try await episode(app, show, 1, 1)
            let e2 = try await episode(app, show, 1, 2)
            let s = service(app)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: "2026-01-01", service: nil)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: nil, service: nil, rewatch: true)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: e2.requireID(), day: nil, service: nil)
            try await s.unmarkEpisode(userID: user.requireID(), episodeID: e1.requireID())
            let remaining = try await watches(app, user: user)
            #expect(remaining.map(\.$episode.id) == [e2.id])
        }
    }

    @Test func markSeasonSkipsWatchedAndUnaired() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 4, 2: 2], unaired: ["1x4"])
            let s = service(app)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            let count = try await s.markSeason(userID: user.requireID(), titleID: show.requireID(), season: 1, service: .primeVideo)
            #expect(count == 2)
            let added = try await watches(app, user: user).filter { $0.watchedOn == nil }
            #expect(added.count == 2)
            #expect(added.allSatisfy { $0.streamingService == .primeVideo })
        }
    }

    @Test func markUpToSpansEarlierSeasons() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [0: 1, 1: 2, 2: 3])
            let target = try await episode(app, show, 2, 2)
            let count = try await service(app).markUpTo(userID: user.requireID(), episodeID: target.requireID(), service: nil)
            #expect(count == 4)
        }
    }

    @Test func ratingBounds() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let s = service(app)
            for bad in [0, 11] {
                await #expect(throws: TrackingError.invalidRating) {
                    try await s.setRating(userID: user.requireID(), titleID: show.requireID(), rating: bad)
                }
            }
            try await s.setRating(userID: user.requireID(), titleID: show.requireID(), rating: 8)
            #expect(try await s.userTitle(userID: user.requireID(), titleID: show.requireID()).rating == 8)
            try await s.setRating(userID: user.requireID(), titleID: show.requireID(), rating: nil)
            #expect(try await s.userTitle(userID: user.requireID(), titleID: show.requireID()).rating == nil)
        }
    }

    @Test func hideMovieRejected() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            await #expect(throws: TrackingError.notFound) {
                try await service(app).setHidden(userID: user.requireID(), titleID: movie.requireID(), hidden: true)
            }
        }
    }

    @Test func markAndUnmarkMovie() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            let s = service(app)
            let watch = try await s.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: "2026-11-01", service: .cinema)
            #expect(watch.$episode.id == nil)
            #expect(watch.streamingService == .cinema)
            _ = try await s.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: nil, service: nil, rewatch: true)
            #expect(try await watches(app, user: user).count == 2)
            try await s.unmarkMovie(userID: user.requireID(), titleID: movie.requireID())
            #expect(try await watches(app, user: user).isEmpty)
        }
    }

    @Test func lastServiceIsMostRecentDatedWatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            let s = service(app)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 2).requireID(), day: "2026-11-05", service: .netflix)
            _ = try await s.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2026-11-01", service: .disneyPlus)
            #expect(try await s.lastService(userID: user.requireID(), titleID: show.requireID()) == .netflix)
        }
    }

    @Test func otherUsersWatchIsNotFound() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let s = service(app)
            let watch = try await s.markEpisode(userID: alice.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            await #expect(throws: TrackingError.notFound) {
                try await s.editWatch(userID: bob.requireID(), watchID: watch.requireID(), day: "2026-01-01", service: nil)
            }
            await #expect(throws: TrackingError.notFound) {
                try await s.deleteWatch(userID: bob.requireID(), watchID: watch.requireID())
            }
            try await s.editWatch(userID: alice.requireID(), watchID: watch.requireID(), day: "2026-01-02", service: .appleTV)
            let reloaded = try await Watch.find(watch.requireID(), on: app.db)
            #expect(reloaded?.watchedOn == "2026-01-02")
            #expect(reloaded?.streamingService == .appleTV)
        }
    }
}

@Suite("Services")
struct ServicesTests {
    @Test func serviceListAndLabels() {
        #expect(StreamingService.allCases == [.netflix, .primeVideo, .disneyPlus, .appleTV, .hboMax, .paramountPlus, .wow, .cinema, .purchased, .other])
        #expect(StreamingService.allCases.map(\.label) == ["Netflix", "Prime Video", "Disney+", "Apple TV+", "HBO Max", "Paramount+", "WOW", "Kino", "Gekauft", "Sonstiges"])
        #expect(StreamingService(rawValue: "purchased") == .purchased)
        #expect(StreamingService(rawValue: "hbo_max") == .hboMax)
        #expect(StreamingService(rawValue: "paramount_plus") == .paramountPlus)
        #expect(StreamingService(rawValue: "wow") == .wow)
        #expect(StreamingService(rawValue: "netflix") == .netflix)   // existing raw values unchanged
    }
}

@Suite("MarkSeries")
struct MarkSeriesTests {
    @Test func markSeriesOnlyAiredRegular() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [0: 1, 1: 2, 2: 2], unaired: ["2x2"])
            let ws = WatchService(db: app.db, today: { "2026-11-07" })
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            let count = try await ws.markSeries(userID: user.requireID(), titleID: show.requireID(), service: nil)
            #expect(count == 2)
            let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
            #expect(watches.count == 3)
            #expect(watches.filter { $0.watchedOn == nil }.count == 2)
            let special = try await episode(app, show, 0, 1)
            #expect(!watches.contains { $0.$episode.id == special.id })
        }
    }
}
