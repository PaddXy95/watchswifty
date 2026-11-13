@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("SingleWatchDelete")
struct SingleWatchDeleteTests {
    func ws(_ app: Application) -> WatchService { WatchService(db: app.db, today: { "2026-11-07" }) }

    @Test func deletesOnlyTheChosenWatch() async throws {
        try await withTestApp { app in
            let userID = try await createUser(app, "pat").requireID()
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let e1 = try await episode(app, show, 1, 1).requireID()
            let first = try await ws(app).markEpisode(userID: userID, episodeID: e1, day: "2026-11-01", service: .netflix)
            _ = try await ws(app).markEpisode(userID: userID, episodeID: e1, day: "2026-11-05", service: .netflix, rewatch: true)

            try await ws(app).deleteWatch(userID: userID, watchID: first.requireID(), titleID: show.requireID(), episodeID: e1)

            let remaining = try await Watch.query(on: app.db).filter(\.$user.$id == userID).all()
            #expect(remaining.map(\.watchedOn) == ["2026-11-05"])
        }
    }

    @Test func watchOfAnotherEpisodeOrTitleIsNotFound() async throws {
        try await withTestApp { app in
            let userID = try await createUser(app, "pat").requireID()
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            let movie = try await seedMovie(app, tmdbID: 603)
            let e1 = try await episode(app, show, 1, 1).requireID()
            let e2 = try await episode(app, show, 1, 2).requireID()
            let episodeWatch = try await ws(app).markEpisode(userID: userID, episodeID: e1, day: nil, service: nil).requireID()
            let movieWatch = try await ws(app).markMovie(userID: userID, titleID: movie.requireID(), day: nil, service: nil).requireID()

            await #expect(throws: TrackingError.notFound) {
                try await ws(app).deleteWatch(userID: userID, watchID: episodeWatch, titleID: show.requireID(), episodeID: e2)
            }
            await #expect(throws: TrackingError.notFound) {
                try await ws(app).deleteWatch(userID: userID, watchID: episodeWatch, titleID: movie.requireID(), episodeID: nil)
            }
            await #expect(throws: TrackingError.notFound) {
                try await ws(app).deleteWatch(userID: userID, watchID: movieWatch, titleID: movie.requireID(), episodeID: e1)
            }
            #expect(try await Watch.query(on: app.db).count() == 2)
        }
    }

    @Test func anotherUsersWatchIsNotFound() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice").requireID()
            let bob = try await createUser(app, "bobby").requireID()
            let movie = try await seedMovie(app, tmdbID: 603)
            let watch = try await ws(app).markMovie(userID: alice, titleID: movie.requireID(), day: nil, service: nil).requireID()
            await #expect(throws: TrackingError.notFound) {
                try await ws(app).deleteWatch(userID: bob, watchID: watch, titleID: movie.requireID(), episodeID: nil)
            }
            #expect(try await Watch.find(watch, on: app.db) != nil)
        }
    }

    @Test func deletingDiscardsLinkedNetflixRows() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let show = try await seedSeries(app, tmdbID: 1, seasons: [4: 2])
            let e1 = try await episode(app, show, 4, 1).requireID()
            let watch = try await ws(app).markEpisode(userID: user.requireID(), episodeID: e1, day: "2026-11-07", service: .netflix)
            let row = try #require(try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).first())
            row.$watch.id = try watch.requireID()
            row.status = RowStatus.matched.rawValue
            try await row.save(on: app.db)

            try await ws(app).deleteWatch(userID: user.requireID(), watchID: watch.requireID(), titleID: show.requireID(), episodeID: e1)

            #expect(try await NetflixRow.find(row.requireID(), on: app.db)?.rowStatus == .discarded)
            #expect(try await Watch.find(watch.requireID(), on: app.db) == nil)
        }
    }
}
