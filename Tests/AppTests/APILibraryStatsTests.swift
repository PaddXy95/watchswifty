@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct LibraryEntryBody: Codable { let kind: String; let tmdbId: Int; let name: String; let rating: Int?; let hidden: Bool }
struct PeriodBody: Codable, Equatable { let movies: Int; let series: Int; let episodes: Int; let minutes: Int; let unknownRuntime: Int }
struct StatsBody: Codable {
    struct Month: Codable { let month: Int; let stats: PeriodBody }
    struct Year: Codable { let year: Int; let stats: PeriodBody; let months: [Month] }
    struct Bucket: Codable { let rating: Int?; let movies: Int; let series: Int; let minutes: Int }
    let total: PeriodBody; let undated: PeriodBody; let years: [Year]; let ratings: [Bucket]; let missingRuntimeTitles: Int
}

@Suite("APILibraryStats")
struct APILibraryStatsTests {
    func get<T: Decodable>(_ type: T.Type, _ app: Application, _ token: String, _ path: String) async throws -> T? {
        var value: T?
        try await app.testing().test(.GET, path, headers: .bearer(token)) { res async in
            #expect(res.status == .ok)
            value = try? res.content.decode(T.self)
        }
        return value
    }

    @Test func libraryFiltersAndSorts() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let ws = WatchService(db: app.db)
            let dark = try await seedSeries(app, tmdbID: 1, name: "Dark", seasons: [1: 1])
            let alien = try await seedMovie(app, tmdbID: 2, name: "Alien")
            let hidden = try await seedSeries(app, tmdbID: 3, name: "Weg", seasons: [1: 1])
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, dark, 1, 1).requireID(), day: "2026-11-01", service: nil)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: alien.requireID(), day: "2026-11-03", service: nil)
            try await ws.setRating(userID: user.requireID(), titleID: dark.requireID(), rating: 9)
            try await ws.setHidden(userID: user.requireID(), titleID: hidden.requireID(), hidden: true)

            let recent = try await get([LibraryEntryBody].self, app, token, "/api/v1/library")
            #expect(recent?.map(\.name) == ["Alien", "Dark"])
            #expect(try await get([LibraryEntryBody].self, app, token, "/api/v1/library?sort=name")?.map(\.name) == ["Alien", "Dark"])
            #expect(try await get([LibraryEntryBody].self, app, token, "/api/v1/library?sort=rating")?.first?.name == "Dark")
            #expect(try await get([LibraryEntryBody].self, app, token, "/api/v1/library?filter=tv")?.map(\.name) == ["Dark"])
            let hiddenOnly = try await get([LibraryEntryBody].self, app, token, "/api/v1/library?filter=hidden")
            #expect(hiddenOnly?.map(\.name) == ["Weg"])
            #expect(hiddenOnly?.first?.hidden == true)
            try await app.testing().test(.GET, "/api/v1/library?filter=kaputt", headers: .bearer(token)) { res async in
                #expect(res.status == .badRequest)   // the spec's enum is enforced
            }
        }
    }

    @Test func statsMatchService() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let movie = try await seedMovie(app, tmdbID: 1, runtime: 120)
            let show = try await seedSeries(app, tmdbID: 2, seasons: [1: 2], runtime: 45)
            let ws = WatchService(db: app.db)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: "2026-01-10", service: nil)
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2025-12-30", service: nil)
            _ = try await ws.markSeason(userID: user.requireID(), titleID: show.requireID(), season: 1, service: nil)   // 1x2 without date
            try await ws.setRating(userID: user.requireID(), titleID: movie.requireID(), rating: 8)
            let stats = try #require(try await get(StatsBody.self, app, token, "/api/v1/stats"))
            #expect(stats.total == PeriodBody(movies: 1, series: 1, episodes: 2, minutes: 210, unknownRuntime: 0))
            #expect(stats.undated.episodes == 1)
            #expect(stats.years.map(\.year) == [2026, 2025])
            #expect(stats.years.first?.months.count == 11)
            #expect(stats.ratings.first { $0.rating == 8 }?.movies == 1)
            #expect(stats.ratings.last?.rating == nil)
        }
    }

    @Test func statsYearFilter() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let movie = try await seedMovie(app, tmdbID: 1, runtime: 100)
            _ = try await WatchService(db: app.db).markMovie(userID: user.requireID(), titleID: movie.requireID(), day: "2025-05-05", service: nil)
            let only2026 = try #require(try await get(StatsBody.self, app, token, "/api/v1/stats?year=2026"))
            #expect(only2026.ratings.allSatisfy { $0.movies == 0 })
            let only2025 = try #require(try await get(StatsBody.self, app, token, "/api/v1/stats?year=2025"))
            #expect(only2025.ratings.last?.movies == 1)
        }
    }
}
