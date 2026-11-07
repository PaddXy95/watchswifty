@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("ContinueWatching")
struct ContinueWatchingTests {
    static let today = "2026-11-07"

    func ws(_ app: Application) -> WatchService { WatchService(db: app.db, today: { Self.today }) }
    func cards(_ app: Application, _ user: User) async throws -> [ContinueCard] {
        try await ContinueWatchingService(db: app.db).cards(userID: user.requireID(), today: Self.today)
    }

    @Test func showsNextEpisodeCard() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, name: "The Mentalist", seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2026-11-05", service: .netflix)
            let result = try await cards(app, user)
            #expect(result.count == 1)
            #expect(result.first?.name == "The Mentalist")
            #expect(result.first?.next.number == 2)
            #expect(result.first?.remaining == 2)
            #expect(result.first?.lastWatchedOn == "2026-11-05")
            #expect(result.first?.lastService == .netflix)
            #expect(result.first?.hasNetflixData == true)
        }
    }

    @Test func hiddenExcluded() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            try await ws(app).setHidden(userID: user.requireID(), titleID: show.requireID(), hidden: true)
            #expect(try await cards(app, user).isEmpty)
        }
    }

    @Test func moviesExcluded() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            _ = try await ws(app).markMovie(userID: user.requireID(), titleID: movie.requireID(), day: nil, service: nil)
            #expect(try await cards(app, user).isEmpty)
        }
    }

    @Test func caughtUpExcluded() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], unaired: ["1x2"])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            #expect(try await cards(app, user).isEmpty)
        }
    }

    @Test func otherUsersWatchesIgnored() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: alice.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            #expect(try await cards(app, bob).isEmpty)
            #expect(try await cards(app, alice).count == 1)
        }
    }

    @Test func sortedByLastWatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let older = try await seedSeries(app, tmdbID: 1, name: "Alt", seasons: [1: 3])
            let newer = try await seedSeries(app, tmdbID: 2, name: "Neu", seasons: [1: 3])
            let undated = try await seedSeries(app, tmdbID: 3, name: "Ohne Datum", seasons: [1: 3])
            _ = try await ws(app).markUpTo(userID: user.requireID(), episodeID: episode(app, undated, 1, 1).requireID(), service: nil)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, newer, 1, 1).requireID(), day: "2026-11-06", service: nil)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, older, 1, 1).requireID(), day: "2026-01-01", service: nil)
            #expect(try await cards(app, user).map(\.name) == ["Neu", "Alt", "Ohne Datum"])
        }
    }

    @Test func netflixFlagFalseForOtherServices() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: .disneyPlus)
            #expect(try await cards(app, user).first?.hasNetflixData == false)
        }
    }

    @Test func singleCardLookup() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            let service = ContinueWatchingService(db: app.db)
            #expect(try await service.card(userID: user.requireID(), titleID: show.requireID(), today: Self.today)?.next.number == 2)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 2).requireID(), day: nil, service: nil)
            #expect(try await service.card(userID: user.requireID(), titleID: show.requireID(), today: Self.today) == nil)
        }
    }
}
