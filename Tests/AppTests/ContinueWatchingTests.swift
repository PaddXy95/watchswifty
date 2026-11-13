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
            #expect(result.first?.watchService == .netflix)
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

    @Test func watchServiceFollowsLastStreamingService() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 4])
            let mark = { (n: Int, day: String, service: StreamingService) in
                _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, n).requireID(), day: day, service: service)
            }
            try await mark(1, "2026-11-01", .disneyPlus)
            #expect(try await cards(app, user).first?.watchService == .disneyPlus)
            try await mark(2, "2026-11-02", .netflix)
            try await mark(3, "2026-11-03", .cinema)   // no streaming link: the latest service that has one counts
            #expect(try await cards(app, user).first?.watchService == .netflix)
        }
    }

    @Test func noWatchServiceWithoutStreaming() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: .purchased)
            #expect(try await cards(app, user).first?.watchService == nil)
        }
    }

    @Test func watchLinksPerService() {
        #expect(StreamingService.netflix.watchLink(for: "The Mentalist")
                == WatchLink(label: "Auf Netflix suchen", url: "https://www.netflix.com/search?q=The%20Mentalist"))
        #expect(StreamingService.primeVideo.watchLink(for: "The Boys")
                == WatchLink(label: "Auf Prime Video suchen", url: "https://www.amazon.de/s?k=The%20Boys&i=instant-video"))
        #expect(StreamingService.appleTV.watchLink(for: "Severance")
                == WatchLink(label: "Auf Apple TV+ suchen", url: "https://tv.apple.com/de/search?term=Severance"))
        #expect(StreamingService.paramountPlus.watchLink(for: "Yellowstone")
                == WatchLink(label: "Auf Paramount+ suchen", url: "https://www.paramountplus.com/de/search/?q=Yellowstone"))
        #expect(StreamingService.disneyPlus.watchLink(for: "Loki") == WatchLink(label: "Disney+ öffnen", url: "https://www.disneyplus.com/"))
        #expect(StreamingService.hboMax.watchLink(for: "X") == WatchLink(label: "HBO Max öffnen", url: "https://play.hbomax.com/"))
        #expect(StreamingService.wow.watchLink(for: "X") == WatchLink(label: "WOW öffnen", url: "https://www.wowtv.de/"))
        #expect(StreamingService.cinema.watchLink(for: "X") == nil)
        #expect(StreamingService.purchased.watchLink(for: "X") == nil)
        #expect(StreamingService.other.watchLink(for: "X") == nil)
        #expect(StreamingService.netflix.watchLink(for: "Fluch & Segen")?.url == "https://www.netflix.com/search?q=Fluch%20%26%20Segen")
    }

    /// The next episode comes after the highest watched regular episode: specials, gaps before it, episodes without
    /// an air date and unaired ones do not count; `remaining` counts the aired ones from there on.
    @Test func nextEpisodeSkipsSpecialsGapsAndUnaired() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let userID = try user.requireID()
            let gaps = try await seedSeries(app, tmdbID: 1, name: "Lücken", seasons: [0: 1, 1: 4, 2: 3],
                                            unaired: ["2x3"], noAirDate: ["1x4"])
            for (season, number) in [(0, 1), (1, 1), (1, 3)] {
                _ = try await ws(app).markEpisode(userID: userID, episodeID: episode(app, gaps, season, number).requireID(),
                                                  day: nil, service: nil)
            }
            let onlySpecial = try await seedSeries(app, tmdbID: 2, name: "Nur Special", seasons: [0: 1, 1: 2])
            _ = try await ws(app).markEpisode(userID: userID, episodeID: episode(app, onlySpecial, 0, 1).requireID(), day: nil,
                                              service: nil)
            let jump = try await seedSeries(app, tmdbID: 3, name: "Sprung", seasons: [1: 2, 2: 2])
            _ = try await ws(app).markEpisode(userID: userID, episodeID: episode(app, jump, 2, 1).requireID(), day: nil, service: nil)

            let byName = Dictionary(uniqueKeysWithValues: try await cards(app, user).map { ($0.name, $0) })
            #expect(Set(byName.keys) == ["Lücken", "Sprung"])
            #expect(byName["Lücken"].map { [$0.next.season, $0.next.number, $0.remaining] } == [2, 1, 2])
            #expect(byName["Lücken"]?.next.name == "Folge 2x1")
            #expect(byName["Sprung"].map { [$0.next.season, $0.next.number, $0.remaining] } == [2, 2, 1])
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
