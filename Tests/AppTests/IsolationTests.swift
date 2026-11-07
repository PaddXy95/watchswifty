@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Isolation")
struct IsolationTests {
    struct World {
        let alice: User
        let bob: User
        let show: Title
        let aliceWatch: Watch
        let aliceHeaders: HTTPHeaders
        let bobHeaders: HTTPHeaders
    }

    /// Alice has a watch, a rating, a hidden series, an import with mappings and unmatched rows; Bob has nothing.
    func withWorld(_ body: (Application, World) async throws -> Void) async throws {
        let tmdb = MatchingWorkerTests.fake(includeShakespeare: false)
        try await withTestApp(tmdb: tmdb) { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, name: "Geteilte Serie", seasons: [1: 2])
            let hiddenShow = try await seedSeries(app, tmdbID: 2, name: "Versteckt bei Alice", seasons: [1: 2])
            let ws = WatchService(db: app.db)
            let watch = try await ws.markEpisode(userID: alice.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                 day: "2026-11-01", service: .netflix)
            try await ws.setRating(userID: alice.requireID(), titleID: show.requireID(), rating: 8)
            _ = try await ws.markEpisode(userID: alice.requireID(), episodeID: episode(app, hiddenShow, 1, 1).requireID(), day: nil, service: nil)
            try await ws.setHidden(userID: alice.requireID(), titleID: hiddenShow.requireID(), hidden: true)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: alice.requireID())
            _ = try await app.matchingWorker.processAll()
            let world = World(alice: alice, bob: bob, show: show, aliceWatch: watch,
                              aliceHeaders: try await login(app, "alice").adding(.htmx),
                              bobHeaders: try await login(app, "bobby").adding(.htmx))
            try await body(app, world)
        }
    }

    @Test func historyOnlyShowsOwnWatches() async throws {
        try await withWorld { app, w in
            try await app.testing().test(.GET, "/history", headers: w.bobHeaders) { res async in
                #expect(!res.body.string.contains("Geteilte Serie"))
                #expect(res.body.string.contains("Noch keine Einträge."))
            }
            try await app.testing().test(.GET, "/history", headers: w.aliceHeaders) { res async in
                #expect(res.body.string.contains("Geteilte Serie"))
            }
        }
    }

    @Test func continueOnlyShowsOwnCards() async throws {
        try await withWorld { app, w in
            try await app.testing().test(.GET, "/", headers: w.bobHeaders) { res async in
                #expect(res.body.string.contains("Noch nichts zum Weiterschauen."))
            }
            try await app.testing().test(.GET, "/", headers: w.aliceHeaders) { res async in
                #expect(res.body.string.contains("Geteilte Serie"))
            }
        }
    }

    @Test func libraryOnlyShowsOwnTitles() async throws {
        try await withWorld { app, w in
            for filter in ["all", "hidden"] {
                try await app.testing().test(.GET, "/library?filter=\(filter)", headers: w.bobHeaders) { res async in
                    #expect(!res.body.string.contains("Geteilte Serie"))
                    #expect(!res.body.string.contains("Versteckt bei Alice"))
                }
            }
        }
    }

    @Test func seriesPageShowsOwnRatingAndChecks() async throws {
        try await withWorld { app, w in
            try await app.testing().test(.GET, "/tv/1", headers: w.bobHeaders) { res async in
                let body = res.body.string
                #expect(body.contains("Staffel 1 · 0/2 gesehen"))
                #expect(!body.contains("★ 8"))
                #expect(!body.contains("01.11.2026"))
            }
            try await app.testing().test(.GET, "/tv/1", headers: w.aliceHeaders) { res async in
                #expect(res.body.string.contains("★ 8"))
                #expect(res.body.string.contains("Staffel 1 · 1/2 gesehen"))
            }
        }
    }

    @Test func importPageOnlyShowsOwnData() async throws {
        try await withWorld { app, w in
            try await app.testing().test(.GET, "/import", headers: w.bobHeaders) { res async in
                let body = res.body.string
                #expect(!body.contains("The Mentalist"))
                #expect(!body.contains("Rick and Morty"))
                #expect(!body.contains("Shakespeare"))
            }
        }
    }

    @Test func foreignIDsAre404() async throws {
        try await withWorld { app, w in
            let watchID = try w.aliceWatch.requireID()
            let mapping = try #require(try await NetflixMapping.query(on: app.db).filter(\.$user.$id == w.alice.requireID()).first())
            let row = try #require(try await NetflixRow.query(on: app.db).filter(\.$user.$id == w.alice.requireID()).first())
            try await app.testing().test(.POST, "/watches/\(watchID)", headers: w.bobHeaders, beforeRequest: { req in
                try req.content.encode(EditWatchInput(day: "2026-01-01", service: ""), as: .urlEncodedForm)
            }, afterResponse: { res async in #expect(res.status == .notFound) })
            try await app.testing().test(.DELETE, "/watches/\(watchID)", headers: w.bobHeaders) { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "/import/mappings/\(mapping.requireID())/accept", headers: w.bobHeaders, beforeRequest: { req in
                try req.content.encode(AcceptInput(kind: "tv", tmdbID: 1001), as: .urlEncodedForm)
            }, afterResponse: { res async in #expect(res.status == .notFound) })
            try await app.testing().test(.POST, "/import/mappings/\(mapping.requireID())/reset", headers: w.bobHeaders) { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/import/mappings/\(mapping.requireID())/search?q=Mentalist", headers: w.bobHeaders) { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "/import/rows/\(row.requireID())/ignore", headers: w.bobHeaders) { res async in
                #expect(res.status == .notFound)
            }
            #expect(try await Watch.find(watchID, on: app.db) != nil)
        }
    }

    @Test func deletingUserRemovesAllTheirData() async throws {
        try await withWorld { app, w in
            let aliceID = try w.alice.requireID()
            let titlesBefore = try await Title.query(on: app.db).count()
            let episodesBefore = try await Episode.query(on: app.db).count()
            let admin = try await login(app, "admin", password: "adminpass123").adding(.htmx)
            try await app.testing().test(.DELETE, "/admin/users/\(aliceID)", headers: admin) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await Watch.query(on: app.db).filter(\.$user.$id == aliceID).count() == 0)
            #expect(try await UserTitle.query(on: app.db).filter(\.$user.$id == aliceID).count() == 0)
            #expect(try await NetflixImport.query(on: app.db).filter(\.$user.$id == aliceID).count() == 0)
            #expect(try await NetflixRow.query(on: app.db).filter(\.$user.$id == aliceID).count() == 0)
            #expect(try await NetflixMapping.query(on: app.db).filter(\.$user.$id == aliceID).count() == 0)
            #expect(try await Title.query(on: app.db).count() == titlesBefore)
            #expect(try await Episode.query(on: app.db).count() == episodesBefore)
        }
    }

    @Test func nonAdminCannotReachAdmin() async throws {
        try await withWorld { app, w in
            try await app.testing().test(.DELETE, "/admin/users/\(w.alice.requireID())", headers: w.bobHeaders) { res async in
                #expect(res.status == .forbidden)
            }
            try await app.testing().test(.GET, "/admin/users", headers: w.bobHeaders) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
