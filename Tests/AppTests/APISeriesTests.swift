@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct SeriesBody: Codable {
    struct Links: Codable { let tmdb: String; let imdb: String?; let rottenTomatoes: String; let seriesGraph: String? }
    struct WatchItem: Codable { let id: UUID; let day: String?; let service: String?; let origin: String }
    struct EpisodeItem: Codable { let season: Int; let number: Int; let name: String; let aired: Bool; let watches: [WatchItem] }
    struct SeasonItem: Codable { let number: Int; let title: String; let watchedCount: Int; let comment: String?; let isOpen: Bool?; let episodes: [EpisodeItem] }
    struct NextItem: Codable { let episodeId: UUID; let season: Int; let number: Int; let name: String }
    let tmdbId: Int
    let name: String
    let rating: Int?
    let comment: String?
    let hidden: Bool
    let followed: Bool
    let lastService: String?
    let links: Links
    let seasons: [SeasonItem]
    let next: NextItem?
}

struct WatchInputBody: Content { var day: String?; var service: String?; var rewatch: Bool? }

@Suite("APISeries")
struct APISeriesTests {
    func setup(_ app: Application, token tmdbToken: String? = "test-token") async throws -> (User, String) {
        let user = try await createUser(app, "pat", tmdbToken: tmdbToken)
        return (user, try await apiToken(app, user))
    }

    func get(_ app: Application, _ token: String, _ path: String) async throws -> (HTTPStatus, SeriesBody?, APIErrorBody?) {
        var result: (HTTPStatus, SeriesBody?, APIErrorBody?) = (.internalServerError, nil, nil)
        try await app.testing().test(.GET, path, headers: .bearer(token)) { res async in
            result = (res.status, try? res.content.decode(SeriesBody.self), try? res.content.decode(APIErrorBody.self))
        }
        return result
    }

    func send<Body: Content>(_ app: Application, _ method: HTTPMethod, _ token: String, _ path: String, _ body: Body?)
        async throws -> (HTTPStatus, SeriesBody?, APIErrorBody?) {
        var result: (HTTPStatus, SeriesBody?, APIErrorBody?) = (.internalServerError, nil, nil)
        try await app.testing().test(method, path, headers: .bearer(token), beforeRequest: { req in
            if let body { try req.content.encode(body, as: .json) }
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(SeriesBody.self), try? res.content.decode(APIErrorBody.self))
        })
        return result
    }

    @Test func seriesDetailMatchesWeb() async throws {
        try await withTestApp { app in
            let (user, token) = try await setup(app)
            let show = try await seedSeries(app, tmdbID: 1, name: "Dark", seasons: [1: 3])
            _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                               day: "2026-11-01", service: .netflix)
            let (status, series, _) = try await get(app, token, "/api/v1/tv/1")
            #expect(status == .ok)
            #expect(series?.name == "Dark")
            #expect(series?.links.tmdb == "https://www.themoviedb.org/tv/1")
            #expect(series?.links.seriesGraph == "https://seriesgraph.com/show/1")
            #expect(series?.lastService == "netflix")
            #expect(series?.seasons.first?.watchedCount == 1)
            #expect(series?.seasons.first?.episodes.first?.watches.first?.day == "2026-11-01")
            #expect(series?.seasons.first?.episodes.first?.aired == true)
        }
    }

    @Test func seriesDetailHasNextEpisodeAndOpenSeason() async throws {
        try await withTestApp { app in
            let (user, token) = try await setup(app)
            let show = try await seedSeries(app, tmdbID: 1, name: "Dark", seasons: [1: 3, 2: 2])
            let (_, fresh, _) = try await get(app, token, "/api/v1/tv/1")
            #expect(fresh?.next == nil)
            #expect(fresh?.seasons.map(\.isOpen) == [true, false])
            _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 3).requireID(),
                                                               day: "2026-11-01", service: .netflix)
            let (status, series, _) = try await get(app, token, "/api/v1/tv/1")
            #expect(status == .ok)
            #expect(series?.next?.season == 2)
            #expect(series?.next?.number == 1)
            let expectedID = try await episode(app, show, 2, 1).requireID()
            #expect(series?.next?.episodeId == expectedID)
            #expect(series?.seasons.map(\.isOpen) == [false, true])
        }
    }

    @Test func markEpisodeWithDateAndService() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            let (status, series, _) = try await send(app, .POST, token, "/api/v1/tv/1/episodes/1/2/watch",
                                                     WatchInputBody(day: "2026-11-02", service: "prime_video"))
            #expect(status == .ok)
            let watch = series?.seasons.first?.episodes[1].watches.first
            #expect(watch?.day == "2026-11-02")
            #expect(watch?.service == "prime_video")
            #expect(watch?.origin == "manual")
            let (_, unmarked, _) = try await send(app, .DELETE, token, "/api/v1/tv/1/episodes/1/2/watch", Optional<WatchInputBody>.none)
            #expect(unmarked?.seasons.first?.episodes[1].watches.isEmpty == true)
        }
    }

    @Test func futureDateIs422() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            let (status, _, error) = try await send(app, .POST, token, "/api/v1/tv/1/episodes/1/1/watch", WatchInputBody(day: "2026-12-01"))
            #expect(status == .unprocessableEntity)
            #expect(error?.code == "validation")
            #expect(error?.message == "Datum liegt in der Zukunft.")
        }
    }

    @Test func unairedEpisodeIs422() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 3], unaired: ["1x3"])
            let (status, _, error) = try await send(app, .POST, token, "/api/v1/tv/1/episodes/1/3/watch", WatchInputBody())
            #expect(status == .unprocessableEntity)
            #expect(error?.message == "Folge ist noch nicht erschienen.")
        }
    }

    @Test func markUpToSeasonAndSeries() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 3, 2: 2])
            let (_, upTo, _) = try await send(app, .POST, token, "/api/v1/tv/1/episodes/1/2/watch-up-to", WatchInputBody())
            #expect(upTo?.seasons.first?.watchedCount == 2)
            let (seasonStatus, season, seasonError) = try await send(app, .POST, token, "/api/v1/tv/1/seasons/1/watch", Optional<WatchInputBody>.none)
            #expect(seasonStatus == .ok, "\(seasonError?.message ?? "")")
            #expect(season?.seasons.first?.watchedCount == 3)
            let (_, all, _) = try await send(app, .POST, token, "/api/v1/tv/1/watch-all", Optional<WatchInputBody>.none)
            #expect(all?.seasons.map(\.watchedCount) == [3, 2])
        }
    }

    @Test func ratingCommentHiddenFollow() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/rating", ["rating": 8]).1?.rating == 8)
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/comment", ["comment": "Super"]).1?.comment == "Super")
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/hidden", ["hidden": true]).1?.hidden == true)
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/follow", ["followed": true]).1?.followed == true)
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/seasons/1/comment", ["comment": "S1"]).1?.seasons.first?.comment == "S1")
            #expect(try await send(app, .PUT, token, "/api/v1/tv/1/rating", [String: Int]()).1?.rating == nil)   // no rating → cleared
        }
    }

    @Test func ratingOutOfRangeIs422() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let (status, _, error) = try await send(app, .PUT, token, "/api/v1/tv/1/rating", ["rating": 11])
            #expect(status == .unprocessableEntity)
            #expect(error?.message == "Bewertung muss zwischen 1 und 10 liegen.")
        }
    }

    @Test func seriesWithoutTMDBToken() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app, token: nil)
            _ = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let (status, _, error) = try await get(app, token, "/api/v1/tv/999")
            #expect(status == .unprocessableEntity)
            #expect(error?.code == "missingTMDBToken")
            #expect(try await get(app, token, "/api/v1/tv/1").0 == .ok)
        }
    }

    @Test func otherUsersDataInvisible() async throws {
        try await withTestApp { app in
            let (_, token) = try await setup(app)
            let other = try await createUser(app, "other")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            _ = try await WatchService(db: app.db).markEpisode(userID: other.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                               day: nil, service: nil)
            try await WatchService(db: app.db).setRating(userID: other.requireID(), titleID: show.requireID(), rating: 3)
            let (_, series, _) = try await get(app, token, "/api/v1/tv/1")
            #expect(series?.seasons.first?.watchedCount == 0)
            #expect(series?.rating == nil)
        }
    }
}
