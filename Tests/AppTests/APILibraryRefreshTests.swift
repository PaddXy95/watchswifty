@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct LibraryRefreshBody: Codable {
    let running: Bool; let done: Int; let total: Int; let failed: Int; let finishedAt: String?; let error: String?
}

@Suite("APILibraryRefresh")
struct APILibraryRefreshTests {
    @Test func startAndPoll() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(RefreshSeed.movie(2))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "anna")
            try await RefreshSeed.watch(app, user, try await seedMovie(app, tmdbID: 2))
            let token = try await apiToken(app, user)
            try await app.testing().test(.POST, "/api/v1/library/refresh", headers: .bearer(token)) { res async in
                #expect(res.status == .accepted)
                #expect((try? res.content.decode(LibraryRefreshBody.self))?.total == 1)
            }
            await app.libraryRefresh.wait(userID: try user.requireID())
            try await app.testing().test(.GET, "/api/v1/library/refresh", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
                let body = try? res.content.decode(LibraryRefreshBody.self)
                #expect(body?.running == false && body?.done == 1 && body?.failed == 0)
                #expect(body?.finishedAt != nil)
            }
        }
    }

    @Test func startWithoutTokenIs422() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "ben", tmdbToken: nil)
            let token = try await apiToken(app, user)
            try await app.testing().test(.POST, "/api/v1/library/refresh", headers: .bearer(token)) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect((try? res.content.decode(APIErrorBody.self))?.code == "missingTMDBToken")
            }
            #expect(tmdb.calls.isEmpty)
        }
    }

    @Test func otherUsersRunIsInvisible() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(RefreshSeed.movie(2))
        try await withTestApp(tmdb: tmdb) { app in
            let anna = try await createUser(app, "anna")
            let ben = try await createUser(app, "ben")
            try await RefreshSeed.watch(app, anna, try await seedMovie(app, tmdbID: 2))
            _ = try await app.libraryRefresh.start(userID: anna.requireID(), token: "test-token")
            await app.libraryRefresh.wait(userID: try anna.requireID())

            let benToken = try await apiToken(app, ben)
            try await app.testing().test(.GET, "/api/v1/library/refresh", headers: .bearer(benToken)) { res async in
                let body = try? res.content.decode(LibraryRefreshBody.self)
                #expect(body?.running == false && body?.total == 0 && body?.finishedAt == nil)
            }
            let benSession = try await login(app, "ben")
            try await app.testing().test(.GET, "/account/tmdb-refresh", headers: benSession.adding(.htmx)) { res async in
                #expect(!res.body.string.contains("Fertig:"))
                #expect(res.body.string.contains("Alle Daten von TMDB neu laden"))
            }
        }
    }
}
