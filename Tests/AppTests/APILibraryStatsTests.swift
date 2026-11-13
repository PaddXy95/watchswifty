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

    struct StatsListsBody: Codable {
        struct Movie: Codable { let tmdbId: Int; let name: String; let watches: Int; let minutes: Int }
        struct EpisodeEntry: Codable { let tmdbId: Int; let seriesName: String; let season: Int; let number: Int; let name: String; let watches: Int }
        struct Completed: Codable { let name: String; let completions: Int }
        struct GenreEntry: Codable { let genre: String; let seriesMinutes: Int; let movieMinutes: Int; let series: Int; let movies: Int }
        struct Service: Codable { let service: String?; let minutes: Int; let episodes: Int?; let movies: Int? }
        let longestMovies: [Movie]
        let mostWatchedMovies: [Movie]
        let mostWatchedEpisodes: [EpisodeEntry]
        let mostCompletedSeries: [Completed]
        let genres: [GenreEntry]
        let services: [Service]
    }

    @Test func statsListsInAPI() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            func watch(_ title: Title, _ episode: Episode? = nil, times: Int) async throws {
                for _ in 0..<times {
                    try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: episode?.requireID(),
                                    watchedOn: "2026-03-01", service: .netflix, origin: .manual).save(on: app.db)
                }
            }
            try await watch(try await seedMovie(app, tmdbID: 10, name: "Oft", runtime: 100, genres: "drama"), times: 3)
            let dark = try await seedSeries(app, tmdbID: 20, name: "Dark", seasons: [1: 1], runtime: 45, genres: "drama")
            try await watch(dark, try await episode(app, dark, 1, 1), times: 2)
            let stats = try #require(try await get(StatsListsBody.self, app, token, "/api/v1/stats?year=2026"))
            #expect(stats.longestMovies.map(\.minutes) == [300])
            #expect(stats.mostWatchedMovies.first?.watches == 3)
            #expect(stats.mostWatchedEpisodes.first.map { "\($0.seriesName) \($0.season)x\($0.number) \($0.watches)" } == "Dark 1x1 2")
            #expect(stats.mostCompletedSeries.first?.completions == 2)
            #expect(stats.genres.first.map { "\($0.genre) \($0.seriesMinutes) \($0.movieMinutes) \($0.series) \($0.movies)" } == "drama 90 300 1 1")
            #expect(stats.services.first.map { "\($0.service ?? "-") \($0.episodes ?? -1) \($0.movies ?? -1)" } == "netflix 2 3")
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

    @Test func apiStatsYearFiltersEverything() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let movie = try await seedMovie(app, tmdbID: 1, runtime: 100)
            let show = try await seedSeries(app, tmdbID: 2, name: "Dark", seasons: [1: 1], runtime: 45)
            let ws = WatchService(db: app.db)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: "2025-05-05", service: .netflix)
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: "2026-01-10", service: .netflix)
            struct Dashboard: Codable {
                struct Bar: Codable { let label: String; let seriesMinutes: Int; let movieMinutes: Int }
                struct Share: Codable { let service: String?; let minutes: Int }
                struct Top: Codable { let tmdbId: Int; let name: String; let minutes: Int }
                let year: Int?; let period: PeriodBody; let previous: PeriodBody?; let chart: [Bar]; let services: [Share]; let topSeries: [Top]
            }
            let body = try #require(try await get(Dashboard.self, app, token, "/api/v1/stats?year=2026"))
            #expect(body.year == 2026)
            #expect(body.period.minutes == 45)
            #expect(body.previous?.minutes == 100)
            #expect(body.chart.first?.seriesMinutes == 45)
            #expect(body.services.first?.service == "netflix")
            #expect(body.topSeries.map(\.name) == ["Dark"])
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
