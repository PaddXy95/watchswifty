@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct NextEpisodeBody: Codable { let episodeId: UUID; let season: Int; let number: Int; let name: String }
struct WatchLinkBody: Codable { let label: String; let url: String }
struct CardBody: Codable {
    let tmdbId: Int; let name: String; let next: NextEpisodeBody; let remaining: Int
    let lastService: String?; let watchLink: WatchLinkBody?
}
struct ShelfBody: Codable { let cards: [CardBody]; let olderCount: Int }
struct NotesBody: Codable {
    struct New: Codable { let tmdbId: Int; let name: String; let count: Int; let first: NextEpisodeBody }
    struct Upcoming: Codable { let tmdbId: Int; let name: String; let count: Int; let next: NextEpisodeBody }
    let newEpisodes: [New]; let upcoming: [Upcoming]
}
struct MovieBody: Codable {
    let tmdbId: Int; let name: String; let rating: Int?; let comment: String?; let watches: [SeriesBody.WatchItem]
}
struct NextBody: Content { var episodeId: UUID? }

@Suite("APIHomeSearchMovie")
struct APIHomeSearchMovieTests {
    func ws(_ app: Application, today: String = "2026-11-07") -> WatchService { WatchService(db: app.db, today: { today }) }

    func decode<T: Decodable>(_ type: T.Type, _ app: Application, _ method: HTTPMethod, _ path: String, token: String,
                              body: (any Content)? = nil) async throws -> (HTTPStatus, T?, APIErrorBody?) {
        var result: (HTTPStatus, T?, APIErrorBody?) = (.internalServerError, nil, nil)
        try await app.testing().test(method, path, headers: .bearer(token), beforeRequest: { req in
            if let body { try req.content.encode(body, as: .json) }
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(T.self), try? res.content.decode(APIErrorBody.self))
        })
        return result
    }

    @Test func continueWatchingCutOffAndAll() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let recent = try await seedSeries(app, tmdbID: 1, name: "Neu", seasons: [1: 3])
            let old = try await seedSeries(app, tmdbID: 2, name: "Alt", seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, recent, 1, 1).requireID(), day: "2026-11-01", service: .netflix)
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, old, 1, 1).requireID(), day: "2026-06-01", service: .netflix)
            let (_, shelf, _) = try await decode(ShelfBody.self, app, .GET, "/api/v1/continue-watching", token: token)
            #expect(shelf?.cards.map(\.name) == ["Neu"])
            #expect(shelf?.olderCount == 1)
            let (_, all, _) = try await decode(ShelfBody.self, app, .GET, "/api/v1/continue-watching?all=true", token: token)
            #expect(all?.cards.map(\.name) == ["Neu", "Alt"])
            #expect(all?.cards.first?.next.number == 2)
            #expect(all?.cards.first?.watchLink?.label == "Auf Netflix suchen")
        }
    }

    @Test func watchLinkForPrimeVideo() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, name: "The Boys", seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2026-11-01", service: .primeVideo)
            let (_, shelf, _) = try await decode(ShelfBody.self, app, .GET, "/api/v1/continue-watching", token: token)
            #expect(shelf?.cards.first?.watchLink?.url == "https://www.amazon.de/s?k=The%20Boys&i=instant-video")
            #expect(shelf?.cards.first?.lastService == "prime_video")
        }
    }

    @Test func markNextAdvancesCard() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2026-11-01", service: nil)
            let next = try await episode(app, show, 1, 2).requireID()
            let (status, card, _) = try await decode(CardBody.self, app, .POST, "/api/v1/tv/1/next", token: token, body: NextBody(episodeId: next))
            #expect(status == .ok)
            #expect(card?.next.number == 3)
            #expect(card?.remaining == 1)
            // A stale episode id (double tap) marks nothing more.
            let (_, again, _) = try await decode(CardBody.self, app, .POST, "/api/v1/tv/1/next", token: token, body: NextBody(episodeId: next))
            #expect(again?.next.number == 3)
            let (_, last, _) = try await decode(CardBody.self, app, .POST, "/api/v1/tv/1/next", token: token, body: NextBody(episodeId: nil))
            #expect(last == nil)   // caught up → 204
        }
    }

    @Test func notesAndUpcoming() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let title = try await seedSeries(app, tmdbID: 1, name: "Beobachtet", seasons: [1: 4], airDates: ["1x3": "2026-11-05", "1x4": "2026-11-12"])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 2).requireID(), day: "2026-10-01", service: nil)
            try await ws(app, today: "2026-10-01").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            let (_, notes, _) = try await decode(NotesBody.self, app, .GET, "/api/v1/notes", token: token)
            #expect(notes?.newEpisodes.map(\.name) == ["Beobachtet"])
            #expect(notes?.newEpisodes.first?.first.number == 3)
            #expect(notes?.upcoming.first?.next.number == 4)
        }
    }

    @Test func dismissHidesNote() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let title = try await seedSeries(app, tmdbID: 1, seasons: [1: 3], airDates: ["1x3": "2026-11-05"])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, title, 1, 2).requireID(), day: "2026-10-01", service: nil)
            try await ws(app, today: "2026-10-01").setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true)
            try await app.testing().test(.POST, "/api/v1/tv/1/new-episodes/dismiss", headers: .bearer(token)) { res async in
                #expect(res.status == .noContent)
            }
            let (_, notes, _) = try await decode(NotesBody.self, app, .GET, "/api/v1/notes", token: token)
            #expect(notes?.newEpisodes.isEmpty == true)
        }
    }

    @Test func searchNeedsTMDBToken() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            let token = try await apiToken(app, user)
            let (status, _, error) = try await decode([String].self, app, .GET, "/api/v1/search?q=Dark", token: token)
            #expect(status == .unprocessableEntity)
            #expect(error?.code == "missingTMDBToken")
        }
    }

    @Test func searchMarksLibrary() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setSearch("multi", "Dark", [TMDBSearchResult(id: 1, kind: .tv, name: "Dark", originalName: nil, year: 2017, posterPath: nil),
                                         TMDBSearchResult(id: 9, kind: .movie, name: "Dark Film", originalName: nil, year: 2020, posterPath: nil)])
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, name: "Dark", seasons: [1: 2])
            _ = try await ws(app).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            struct Hit: Codable { let kind: String; let tmdbId: Int; let inLibrary: Bool; let watchedEpisodes: Int?; let totalEpisodes: Int? }
            let (status, hits, _) = try await decode([Hit].self, app, .GET, "/api/v1/search?q=Dark", token: token)
            #expect(status == .ok)
            #expect(hits?.map(\.tmdbId) == [1, 9])
            #expect(hits?.first?.inLibrary == true)
            #expect(hits?.first?.watchedEpisodes == 1)
            #expect(hits?.first?.totalEpisodes == 2)
            #expect(hits?.last?.inLibrary == false)
            let (_, short, _) = try await decode([Hit].self, app, .GET, "/api/v1/search?q=D", token: token)
            #expect(short?.isEmpty == true)
        }
    }

    @Test func movieWatchRewatchUnwatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            _ = try await seedMovie(app, tmdbID: 603, name: "Matrix", runtime: 136)
            let (status, movie, _) = try await decode(MovieBody.self, app, .POST, "/api/v1/movies/603/watch", token: token,
                                                      body: WatchInputBody(day: "2026-11-01", service: "cinema"))
            #expect(status == .ok)
            #expect(movie?.watches.first?.service == "cinema")
            let (_, again, _) = try await decode(MovieBody.self, app, .POST, "/api/v1/movies/603/watch", token: token,
                                                 body: WatchInputBody(day: "2026-11-05", rewatch: true))
            #expect(again?.watches.map(\.day) == ["2026-11-05", "2026-11-01"])
            let (_, none, _) = try await decode(MovieBody.self, app, .DELETE, "/api/v1/movies/603/watch", token: token)
            #expect(none?.watches.isEmpty == true)
        }
    }

    @Test func movieRatingAndComment() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            _ = try await seedMovie(app, tmdbID: 603, name: "Matrix", runtime: 136)
            #expect(try await decode(MovieBody.self, app, .PUT, "/api/v1/movies/603/rating", token: token, body: ["rating": 9]).1?.rating == 9)
            #expect(try await decode(MovieBody.self, app, .PUT, "/api/v1/movies/603/comment", token: token, body: ["comment": "Kino!"]).1?.comment == "Kino!")
            let (_, movie, _) = try await decode(MovieBody.self, app, .GET, "/api/v1/movies/603", token: token)
            #expect(movie?.name == "Matrix")
        }
    }
}
