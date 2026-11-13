@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AccountRefresh")
struct AccountRefreshTests {
    @Test func tokenBlockShowsRefreshButtonOnlyWithToken() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            try await createUser(app, "ben", tmdbToken: nil)
            let anna = try await login(app, "anna")
            let ben = try await login(app, "ben")
            try await app.testing().test(.GET, "/account", headers: anna) { res async in
                #expect(res.body.string.contains("Alle Daten von TMDB neu laden"))
            }
            try await app.testing().test(.GET, "/account", headers: ben) { res async in
                #expect(!res.body.string.contains("Alle Daten von TMDB neu laden"))
            }
        }
    }

    @Test func idlePollShowsButton() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            let anna = try await login(app, "anna")
            try await app.testing().test(.GET, "/account/tmdb-refresh", headers: anna.adding(.htmx)) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains(#"id="library-refresh""#))
                #expect(body.contains("Alle Daten von TMDB neu laden"))
                #expect(!body.contains("every 2s"))
            }
        }
    }

    @Test func startShowsProgressThenResult() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(RefreshSeed.series(1), episodes: [1: ["Pilot"]])
        tmdb.delay = .milliseconds(100)
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedSeries(app, tmdbID: 1, seasons: [1: 1]))
            let anna = try await login(app, "anna")
            try await app.testing().test(.POST, "/account/tmdb-refresh", headers: anna.adding(.htmx)) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("Lädt neu … 0 von 1"))
                #expect(body.contains(#"hx-trigger="every 2s""#))
            }
            await app.libraryRefresh.wait(userID: try user.requireID())
            try await app.testing().test(.GET, "/account/tmdb-refresh", headers: anna.adding(.htmx)) { res async in
                let body = res.body.string
                #expect(body.contains("Fertig: 1 Titel neu geladen"))
                #expect(!body.contains("fehlgeschlagen"))
                #expect(body.contains(#"href="/library""#))
                #expect(!body.contains("every 2s"))
            }
        }
    }

    @Test func newTokenClearsTheStoppedRunsMessage() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .unauthorized
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 2))
            let anna = try await login(app, "anna")
            _ = try await app.libraryRefresh.start(userID: user.requireID(), token: "test-token")
            await app.libraryRefresh.wait(userID: try user.requireID())
            try await app.testing().test(.GET, "/account/tmdb-refresh", headers: anna.adding(.htmx)) { res async in
                let body = res.body.string
                #expect(body.contains(TMDBError.unauthorized.description))
                #expect(body.contains("Alle Daten von TMDB neu laden"))   // the button is back
            }
            tmdb.failure = nil
            try await app.testing().test(.POST, "/account/tmdb-token", headers: anna, beforeRequest: { req in
                try req.content.encode(AccountController.TokenInput(token: "neuer-token"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                let body = res.body.string
                #expect(body.contains("TMDB-Token gespeichert."))
                #expect(!body.contains(TMDBError.unauthorized.description))
            })
        }
    }

    @Test func removingTheTokenStopsARunningReload() async throws {
        let tmdb = FakeTMDBClient()
        for id in 1...3 { tmdb.addMovie(RefreshSeed.movie(id)) }
        tmdb.delay = .milliseconds(200)
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            for id in 1...3 { try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: id)) }
            let anna = try await login(app, "anna")
            _ = try await app.libraryRefresh.start(userID: user.requireID(), token: "test-token")
            try await app.testing().test(.POST, "/account/tmdb-token/remove", headers: anna) { res async in
                #expect(res.body.string.contains("TMDB-Token entfernt."))
            }
            await app.libraryRefresh.wait(userID: try user.requireID())
            #expect(await app.libraryRefresh.state(userID: try user.requireID()) == .idle)
            #expect(tmdb.calls.count < 3)
        }
    }

    @Test func startWithoutTokenShowsError() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "ben", tmdbToken: nil)
            let ben = try await login(app, "ben")
            try await app.testing().test(.POST, "/account/tmdb-refresh", headers: ben.adding(.htmx)) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Kein TMDB-Token hinterlegt – bitte unter Konto eintragen."))
            }
            #expect(tmdb.calls.isEmpty)
        }
    }
}
