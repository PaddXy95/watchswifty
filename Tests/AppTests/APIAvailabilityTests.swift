@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("APIAvailability")
struct APIAvailabilityTests {
    struct OfferBody: Codable { let providerId: Int; let name: String; let logoPath: String?; let kind: String; let mine: Bool }
    struct AvailabilityBody: Codable { let region: String; let fetchedAt: Date?; let offers: [OfferBody] }
    struct ItemBody: Codable { let kind: String; let tmdbId: Int; let name: String; let addedAt: Date; let availability: AvailabilityBody? }
    struct ListBody: Codable { let region: String; let items: [ItemBody] }
    struct WatchLaterBody: Content { var watchLater: Bool }
    struct ServicesBody: Content { var region: String; var providerIds: [Int] }
    struct ProviderBody: Codable { let providerId: Int; let name: String }
    struct RegionBody: Codable { let code: String; let name: String }
    struct PrefsBody: Codable { let titleAvailable: Bool }
    struct FlagBody: Codable { let watchLater: Bool? }
    struct PrefsUpdate: Content { var announced: Bool; var soon: Bool; var today: Bool; var channel: String; var titleAvailable: Bool? }

    func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil))
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate),
                                                                                       offer(2, "Apple TV", .buy)]]))
        tmdb.setRegions([TMDBRegion(code: "DE", name: "Deutschland")])
        tmdb.setProviders(kind: .movie, region: "DE", [TMDBProviderInfo(providerID: 8, name: "Netflix", logoPath: nil, displayPriority: 1)])
        return tmdb
    }

    func setup(_ app: Application, tmdbToken: Bool = true) async throws -> (User, String) {
        let user = try await createUser(app, "pat", tmdbToken: tmdbToken ? try app.tokenCipher.seal("tok") : nil)
        return (user, try await apiToken(app, user))
    }

    func call<Body: Content>(_ app: Application, _ method: HTTPMethod, _ path: String, _ token: String, body: Body? = Optional<WatchLaterBody>.none,
                             check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(method, path, headers: .bearer(token), beforeRequest: { req in
            if let body { try req.content.encode(body, as: .json) }
        }, afterResponse: check)
    }

    @Test func watchLaterRoundTrip() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (pat, token) = try await setup(app)
            try await UserStreamingService(userID: pat.requireID(), providerID: 8).save(on: app.db)
            try await call(app, .PUT, "/api/v1/movies/603/watch-later", token, body: WatchLaterBody(watchLater: true)) { res in
                #expect(res.status == .noContent)
            }
            try await call(app, .GET, "/api/v1/watch-later", token) { res in
                #expect(res.status == .ok)
                let list = try res.content.decode(ListBody.self)
                #expect(list.region == "DE")
                #expect(list.items.map(\.name) == ["Matrix"])
                #expect(list.items.first?.availability?.offers.first { $0.providerId == 8 }?.mine == true)
            }
            try await call(app, .GET, "/api/v1/movies/603", token) { res in
                let decoded = try res.content.decode(FlagBody.self)
                #expect(decoded.watchLater == true)
            }
            try await call(app, .PUT, "/api/v1/movies/603/watch-later", token, body: WatchLaterBody(watchLater: false)) { res in
                #expect(res.status == .noContent)
            }
            #expect(try await WatchLaterEntry.query(on: app.db).count() == 0)
        }
    }

    @Test func unknownTitleIs404() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, token) = try await setup(app)
            try await call(app, .PUT, "/api/v1/movies/999/watch-later", token, body: WatchLaterBody(watchLater: true)) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func availabilityFetchesWhenMissing() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, token) = try await setup(app)
            try await call(app, .GET, "/api/v1/movies/603/availability", token) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AvailabilityBody.self)
                #expect(body.fetchedAt != nil)
                #expect(body.offers.map(\.kind).sorted() == ["buy", "flatrate"])
            }
            #expect(tmdb.calls.filter { $0 == "watch_providers:movie:603" }.count == 1)
        }
    }

    @Test func tokenlessUserGetsStoredStateOrError() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, token) = try await setup(app, tmdbToken: false)
            let movie = try await seedMovie(app, tmdbID: 603)
            try await WatchLaterEntry(userID: pat.requireID(), titleID: movie.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            try await call(app, .GET, "/api/v1/movies/603/availability", token) { res in
                #expect(res.status == .unprocessableEntity)   // nothing stored, no token: missingTMDBToken
                #expect(res.body.string.contains("missingTMDBToken"))
            }
            try await AvailabilityService(db: app.db).refresh(movie, tmdb: tmdb, now: Date().addingTimeInterval(-10 * 86_400))
            try await call(app, .GET, "/api/v1/movies/603/availability", token) { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AvailabilityBody.self)
                #expect(decoded.offers.count == 2)
            }
        }
    }

    @Test func otherUsersListIsInvisible() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let other = try await createUser(app, "sepp")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await WatchLaterEntry(userID: other.requireID(), titleID: movie.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            let (_, token) = try await setup(app)
            try await call(app, .GET, "/api/v1/watch-later", token) { res in
                let decoded = try res.content.decode(ListBody.self)
                #expect(decoded.items.isEmpty)
            }
        }
    }

    @Test func streamingServicesRoundTrip() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, token) = try await setup(app)
            try await call(app, .PUT, "/api/v1/me/streaming-services", token, body: ServicesBody(region: "AT", providerIds: [8])) { res in
                #expect(res.status == .ok)
            }
            try await call(app, .GET, "/api/v1/me/streaming-services", token) { res in
                let body = try res.content.decode(ServicesBody.self)
                #expect(body.region == "AT" && body.providerIds == [8])
            }
            try await call(app, .PUT, "/api/v1/me/streaming-services", token, body: ServicesBody(region: "x", providerIds: [])) { res in
                #expect(res.status == .unprocessableEntity)
            }
            try await call(app, .GET, "/api/v1/streaming-providers?region=DE", token) { res in
                let decoded = try res.content.decode([ProviderBody].self)
                #expect(decoded.map(\.name) == ["Netflix"])
            }
            try await call(app, .GET, "/api/v1/streaming-regions", token) { res in
                let decoded = try res.content.decode([RegionBody].self)
                #expect(decoded.map(\.code) == ["DE"])
            }
        }
    }

    @Test func notificationsKeepTitleAvailableWhenAbsent() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (pat, token) = try await setup(app)
            pat.notifyAvailable = true
            try await pat.save(on: app.db)
            try await call(app, .PUT, "/api/v1/me/notifications", token,
                           body: PrefsUpdate(announced: false, soon: false, today: false, channel: "mail", titleAvailable: nil)) { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(PrefsBody.self)
                #expect(decoded.titleAvailable == true)
            }
            try await call(app, .PUT, "/api/v1/me/notifications", token,
                           body: PrefsUpdate(announced: false, soon: false, today: false, channel: "mail", titleAvailable: false)) { res in
                let decoded = try res.content.decode(PrefsBody.self)
                #expect(decoded.titleAvailable == false)
            }
        }
    }

    @Test func searchCarriesWatchLater() async throws {
        let tmdb = fake()
        tmdb.setSearch("multi", "ma", [TMDBSearchResult(id: 603, kind: .movie, name: "Matrix", originalName: nil, year: 1999, posterPath: nil)])
        try await withTestApp(tmdb: tmdb) { app in
            let (_, token) = try await setup(app)
            try await call(app, .PUT, "/api/v1/movies/603/watch-later", token, body: WatchLaterBody(watchLater: true)) { _ in }
            try await call(app, .GET, "/api/v1/search?q=ma", token) { res in
                let decoded = try res.content.decode([FlagBody].self)
                #expect(decoded.first?.watchLater == true)
            }
        }
    }
}
