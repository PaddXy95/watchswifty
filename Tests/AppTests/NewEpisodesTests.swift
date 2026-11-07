@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct FollowInput: Content { var followed: Bool }

@Suite("NewEpisodes")
struct NewEpisodesTests {
    static let today = "2026-11-07"

    /// Series 1: S1E1–2 aired 2020, S1E3 aired 2026-11-05 (new), S1E4 aired 2026-11-20 (future).
    func seed(_ app: Application, tmdbID: Int = 1, name: String = "Beobachtet") async throws -> Title {
        try await seedSeries(app, tmdbID: tmdbID, name: name, seasons: [1: 4], airDates: ["1x3": "2026-11-05", "1x4": "2026-11-20"])
    }

    func ws(_ app: Application, today: String = NewEpisodesTests.today) -> WatchService { WatchService(db: app.db, today: { today }) }

    func notes(_ app: Application, _ user: User) async throws -> [NewEpisodesNote] {
        try await NewEpisodesService(db: app.db).notes(userID: user.requireID(), today: Self.today)
    }

    @Test func followToggle() async throws {
        try await withTestApp(tmdb: TitlePagesTests.fake()) { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.body.string.contains("Beobachten"))
            }
            try await app.testing().test(.POST, "/tv/1399/follow", headers: headers, beforeRequest: { req in
                try req.content.encode(FollowInput(followed: true), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Nicht mehr beobachten"))
            })
            let entry = try await UserTitle.query(on: app.db).filter(\.$user.$id == user.requireID()).first()
            #expect(entry?.isFollowed == true)
            #expect(entry?.followedOn == "2026-11-07")
        }
    }

    @Test func onlyFollowedSeriesGetNotes() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let followed = try await seed(app, tmdbID: 1, name: "Beobachtet")
            let other = try await seed(app, tmdbID: 2, name: "Nicht beobachtet")
            for title in [followed, other] {
                _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 2).requireID(), day: "2026-10-01", service: nil)
            }
            try await ws(app, today: "2026-10-01").setFollowed(userID: user.requireID(), titleID: followed.requireID(), followed: true)
            let result = try await notes(app, user)
            #expect(result.map(\.name) == ["Beobachtet"])
        }
    }

    @Test func backlogBeforeFollowIsIgnored() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seed(app)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 1).requireID(), day: "2021-01-01", service: nil)
            // Followed today: S1E2 (2020) and S1E3 (2026-11-05) aired before → backlog, no note.
            try await ws(app).setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            #expect(try await notes(app, user).isEmpty)
        }
    }

    @Test func newEpisodeAfterFollowShows() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seed(app)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 2).requireID(), day: "2026-10-01", service: nil)
            try await ws(app, today: "2026-10-02").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            let result = try await notes(app, user)
            #expect(result.count == 1)
            #expect(result.first?.count == 1)
            #expect(result.first?.first.code == "S01E03")
        }
    }

    @Test func watchingTheNewEpisodeClearsNote() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seed(app)
            try await ws(app, today: "2026-10-02").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 3).requireID(), day: "2026-11-06", service: nil)
            #expect(try await notes(app, user).isEmpty)
        }
    }

    @Test func dismissClearsUntilNextEpisode() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seed(app)
            try await ws(app, today: "2026-10-02").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            #expect(try await notes(app, user).count == 1)
            try await ws(app, today: "2026-11-06").dismissNewEpisodes(userID: user.requireID(), titleID: title.requireID())
            #expect(try await notes(app, user).isEmpty)
            // S1E4 airs on 2026-11-20 → on that day the note is back.
            let later = try await NewEpisodesService(db: app.db).notes(userID: user.requireID(), today: "2026-11-20")
            #expect(later.first?.first.code == "S01E04")
        }
    }

    @Test func homeShowsNewEpisodesBox() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(!res.body.string.contains("Neue Folgen"))
            }
            let title = try await seed(app)
            try await ws(app, today: "2026-10-02").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains("Neue Folgen"))
                #expect(res.body.string.contains("Beobachtet"))
                #expect(res.body.string.contains("1 neue Folge"))
                #expect(res.body.string.contains("/tv/1/new-episodes/dismiss"))
            }
            try await app.testing().test(.POST, "/tv/1/new-episodes/dismiss", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await notes(app, user).isEmpty)
        }
    }

    @Test func followsArePrivate() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let title = try await seed(app)
            try await ws(app, today: "2026-10-02").setFollowed(userID: alice.requireID(), titleID: title.requireID(), followed: true)
            #expect(try await notes(app, bob).isEmpty)
            #expect(try await notes(app, alice).count == 1)
        }
    }

    @Test func hiddenFollowedSeriesStillRefreshed() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seed(app)
            try await ws(app).setHidden(userID: user.requireID(), titleID: title.requireID(), hidden: true)
            #expect(try await seriesDueForRefresh(on: app.db).isEmpty)
            try await ws(app).setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            #expect(try await seriesDueForRefresh(on: app.db).map(\.tmdbID) == [1])
        }
    }
}
