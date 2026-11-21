@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Upgrade test fixture generator for v0.1.0, run inside a v0.1.0 checkout by `scripts/upgrade-fixtures/generate.sh`.
/// Writes a populated database to `$UPGRADE_FIXTURE_PATH` with the real 0.1.0 services; `UpgradeTests` checks it.
@Suite("UpgradeFixtureGenerator")
struct UpgradeFixtureGenerator {
    @Test func generate() async throws {
        guard let path = ProcessInfo.processInfo.environment["UPGRADE_FIXTURE_PATH"] else { return }
        try? FileManager.default.removeItem(atPath: path)
        var config = AppConfig.testing
        config.databasePath = path
        config.tokenKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
        let tmdb = MatchingWorkerTests.fake()
        tmdb.setSearch("tv", "Rick and Morty", [
            TMDBSearchResult(id: 1, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2013, posterPath: "/rm.jpg"),
            TMDBSearchResult(id: 2, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2020, posterPath: nil),
        ])
        try await withTestApp(config: config, tmdb: tmdb) { app in
            let pat = try await createUser(app, "pat", tmdbToken: nil)
            pat.tmdbToken = try app.tokenCipher.seal("fixture-tmdb-token")
            try await pat.save(on: app.db)
            let kim = try await createUser(app, "kim", tmdbToken: nil)
            let patID = try pat.requireID(), kimID = try kim.requireID()

            let series = try await seedSeries(app, tmdbID: 500, name: "Fixture Serie", seasons: [1: 3, 2: 2],
                                              unaired: ["2x2"], status: "Returning Series", runtime: 45,
                                              episodeRuntimes: ["1x1": 50])
            series.overview = "Eine Serie zum Testen."
            series.posterPath = "/serie.jpg"
            series.year = 2020
            series.imdbID = "tt0000500"
            try await series.save(on: app.db)
            let movie = try await seedMovie(app, tmdbID: 600, name: "Fixture Film", runtime: 120)
            let hiddenSeries = try await seedSeries(app, tmdbID: 601, name: "Versteckte Serie", seasons: [1: 2], status: "Ended")

            var watches = WatchService(db: app.db)
            watches.today = config.today
            let s1e1 = try await episode(app, series, 1, 1)
            let s1e2 = try await episode(app, series, 1, 2)
            _ = try await watches.markEpisode(userID: patID, episodeID: s1e1.requireID(), day: "2026-01-02", service: .netflix)
            _ = try await watches.markEpisode(userID: patID, episodeID: s1e1.requireID(), day: "2026-03-04", service: .netflix, rewatch: true)
            _ = try await watches.markEpisode(userID: patID, episodeID: s1e2.requireID(), day: nil, service: nil)
            try await watches.setRating(userID: patID, titleID: series.requireID(), rating: 4)
            try await watches.setComment(userID: patID, titleID: series.requireID(), comment: "Kommentar zur Serie")
            try await watches.setSeasonComment(userID: patID, titleID: series.requireID(), season: 1, comment: "Staffel 1 war gut")
            try await watches.setFollowed(userID: patID, titleID: series.requireID(), followed: true)
            _ = try await watches.markMovie(userID: patID, titleID: movie.requireID(), day: "2025-12-24", service: .disneyPlus)
            _ = try await watches.markSeason(userID: patID, titleID: hiddenSeries.requireID(), season: 1, service: .wow)
            try await watches.setHidden(userID: patID, titleID: hiddenSeries.requireID(), hidden: true)
            _ = try await watches.markSeries(userID: kimID, titleID: series.requireID(), service: .primeVideo)
            try await watches.setRating(userID: kimID, titleID: movie.requireID(), rating: 2)

            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "NetflixViewingHistory.csv",
                                                           userID: patID)
            let worker = MatchingWorker(db: app.db, provider: TMDBProvider { _ in tmdb }, logger: app.logger,
                                        cipher: app.tokenCipher, enabled: false)
            _ = try await worker.processAll()

            _ = try await login(app, "pat")
        }
    }
}
