@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("DailyRefresh")
struct DailyRefreshTests {
    func due(_ app: Application) async throws -> [Int] {
        try await seriesDueForRefresh(on: app.db).map(\.tmdbID).sorted()
    }

    func entry(_ app: Application, _ user: User, _ title: Title, hidden: Bool) async throws {
        try await WatchService(db: app.db).setHidden(userID: user.requireID(), titleID: title.requireID(), hidden: hidden)
    }

    @Test func dueWhenInLibraryAndVisible() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await entry(app, user, show, hidden: false)
            #expect(try await due(app) == [1])
        }
    }

    @Test func notDueWhenHiddenByEveryone() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await entry(app, alice, show, hidden: true)
            try await entry(app, bob, show, hidden: true)
            #expect(try await due(app).isEmpty)
        }
    }

    @Test func dueWhenHiddenByOneVisibleForAnother() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await entry(app, alice, show, hidden: true)
            try await entry(app, bob, show, hidden: false)
            #expect(try await due(app) == [1])
        }
    }

    @Test func notDueWhenEndedOrCanceled() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let ended = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], status: "Ended")
            let canceled = try await seedSeries(app, tmdbID: 2, seasons: [1: 1], status: "Canceled")
            try await entry(app, user, ended, hidden: false)
            try await entry(app, user, canceled, hidden: false)
            #expect(try await due(app).isEmpty)
        }
    }

    @Test func moviesNeverDue() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 3)
            try await WatchService(db: app.db).setRating(userID: user.requireID(), titleID: movie.requireID(), rating: 7)
            #expect(try await due(app).isEmpty)
        }
    }

    @Test func notDueWhenInNoLibrary() async throws {
        try await withTestApp { app in
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            #expect(try await due(app).isEmpty)
        }
    }
}

@Suite("RefreshToken")
struct RefreshTokenTests {
    @Test func picksVisibleOwnerWithToken() async throws {
        try await withTestApp { app in
            let hiddenOwner = try await createUser(app, "versteckt", tmdbToken: "hidden-token")
            let noToken = try await createUser(app, "ohne", tmdbToken: nil)
            let visible = try await createUser(app, "sichtbar", tmdbToken: "visible-token")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let ws = WatchService(db: app.db)
            try await ws.setHidden(userID: hiddenOwner.requireID(), titleID: show.requireID(), hidden: true)
            try await ws.setHidden(userID: noToken.requireID(), titleID: show.requireID(), hidden: false)
            #expect(try await refreshToken(for: show.requireID(), on: app.db, cipher: app.tokenCipher) == nil)
            try await ws.setHidden(userID: visible.requireID(), titleID: show.requireID(), hidden: false)
            #expect(try await refreshToken(for: show.requireID(), on: app.db, cipher: app.tokenCipher) == "visible-token")
        }
    }

    @Test func refreshTokenFromFollowerWhoHidSeries() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat", tmdbToken: "follower-token")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let ws = WatchService(db: app.db)
            try await ws.setFollowed(userID: pat.requireID(), titleID: show.requireID(), followed: true)
            try await ws.setHidden(userID: pat.requireID(), titleID: show.requireID(), hidden: true)
            #expect(try await refreshToken(for: show.requireID(), on: app.db, cipher: app.tokenCipher) == "follower-token")
        }
    }
}
