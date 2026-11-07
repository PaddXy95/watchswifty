@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("MatchingWorker")
struct MatchingWorkerTests {
    static func fake(includeShakespeare: Bool = true) -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.setSearch("tv", "The Mentalist", [
            TMDBSearchResult(id: 1001, kind: .tv, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil),
            TMDBSearchResult(id: 1002, kind: .tv, name: "The Mentalist: Specials", originalName: nil, year: 2010, posterPath: nil),
        ])
        var season4 = ["Scharlachrote Briefe", "Die Aura des Todes"]
        if includeShakespeare { season4.append("Keine Lust auf Shakespeare") }
        tmdb.addSeries(TMDBSeries(id: 1001, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4]),
                       episodes: [1: ["Pilot"], 4: season4], airDate: "2011-01-01")
        return tmdb
    }

    func worker(_ app: Application, _ tmdb: FakeTMDBClient) -> MatchingWorker {
        MatchingWorker(db: app.db, tmdb: tmdb, logger: app.logger, enabled: false)
    }

    func rows(_ app: Application, _ user: User, containing text: String) async throws -> [NetflixRow] {
        try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).all().filter { $0.rawTitle.contains(text) }
    }

    func mentalistEpisode(_ app: Application, _ name: String) async throws -> Episode {
        guard let e = try await Episode.query(on: app.db).filter(\.$name == name).first() else { fatalError("missing \(name)") }
        return e
    }

    @Test func autoMatchedSeriesCreatesWatches() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let result = try await worker(app, tmdb).processAll()
            #expect(result.matched >= 4)
            let mentalist = try await rows(app, user, containing: "The Mentalist")
            #expect(mentalist.count == 4)
            #expect(mentalist.allSatisfy { $0.rowStatus == .matched && $0.$watch.id != nil })
            let aura = try await mentalistEpisode(app, "Die Aura des Todes")
            let watches = try await Watch.query(on: app.db).filter(\.$episode.$id == aura.requireID()).all()
            #expect(watches.count == 1)
            #expect(watches.first?.watchedOn == "2026-11-07")
            #expect(watches.first?.watchOrigin == .import)
            #expect(watches.first?.streamingService == .netflix)
            let mapping = try #require(try await NetflixMapping.query(on: app.db).filter(\.$netflixName == "The Mentalist").first())
            #expect(mapping.mappingStatus == .auto)
        }
    }

    @Test func ambiguousShowGoesToReview() async throws {
        let tmdb = Self.fake()
        tmdb.setSearch("tv", "Rick and Morty", [
            TMDBSearchResult(id: 1, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2013, posterPath: nil),
            TMDBSearchResult(id: 2, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2020, posterPath: nil),
        ])
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let result = try await worker(app, tmdb).processAll()
            let mapping = try #require(try await NetflixMapping.query(on: app.db).filter(\.$netflixName == "Rick and Morty").first())
            #expect(mapping.mappingStatus == .review)
            #expect(mapping.candidateResults.map(\.id) == [1, 2])
            #expect(try await rows(app, user, containing: "Rick and Morty").allSatisfy { $0.rowStatus == .pending })
            #expect(result.awaitingReview > 0)
        }
    }

    @Test func ignoredMappingIgnoresRows() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let w = worker(app, tmdb)
            _ = try await w.processAll()
            let mapping = try #require(try await NetflixMapping.query(on: app.db).filter(\.$netflixName == "Rick and Morty").first())
            mapping.status = MappingStatus.ignored.rawValue
            try await mapping.save(on: app.db)
            _ = try await w.processAll()
            #expect(try await rows(app, user, containing: "Rick and Morty").allSatisfy { $0.rowStatus == .ignored })
        }
    }

    @Test func unknownEpisodeUnmatched() async throws {
        let tmdb = Self.fake(includeShakespeare: false)
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let row = try #require(try await rows(app, user, containing: "Shakespeare").first)
            #expect(row.rowStatus == .unmatched)
            #expect(row.$watch.id == nil)
        }
    }

    @Test func mergesWithManualWatchWithinOneDay() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 1001)
            let aura = try await mentalistEpisode(app, "Die Aura des Todes")
            let manual = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: aura.requireID(),
                                                                        day: "2026-11-06", service: .netflix)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let watches = try await Watch.query(on: app.db).filter(\.$episode.$id == aura.requireID()).all()
            #expect(watches.map(\.id) == [manual.id])
            let row = try #require(try await rows(app, user, containing: "Aura").first)
            #expect(row.$watch.id == manual.id)
        }
    }

    @Test func doesNotMergeOtherService() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 1001)
            let aura = try await mentalistEpisode(app, "Die Aura des Todes")
            _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: aura.requireID(), day: "2026-11-07", service: .disneyPlus)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            #expect(try await Watch.query(on: app.db).filter(\.$episode.$id == aura.requireID()).count() == 2)
        }
    }

    @Test func undatedManualWatchTakesCSVDate() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 1001)
            let aura = try await mentalistEpisode(app, "Die Aura des Todes")
            _ = try await WatchService(db: app.db).markUpTo(userID: user.requireID(), episodeID: aura.requireID(), service: nil)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let watches = try await Watch.query(on: app.db).filter(\.$episode.$id == aura.requireID()).all()
            #expect(watches.count == 1)
            #expect(watches.first?.watchedOn == "2026-11-07")
        }
    }

    @Test func singleRowMovieFallback() async throws {
        let tmdb = Self.fake()
        tmdb.setSearch("movie", "Mission: Impossible – Dead Reckoning", [
            TMDBSearchResult(id: 575264, kind: .movie, name: "Mission: Impossible – Dead Reckoning", originalName: nil, year: 2023, posterPath: nil),
        ])
        tmdb.addMovie(TMDBMovie(id: 575264, name: "Mission: Impossible – Dead Reckoning", originalName: nil, year: 2023, posterPath: nil))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: "Title,Date\n\"Mission: Impossible – Dead Reckoning\",\"1/1/24\"\n",
                                                          filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let row = try #require(try await rows(app, user, containing: "Mission").first)
            #expect(row.rowStatus == .matched)
            let watch = try #require(try await Watch.find(row.$watch.id, on: app.db))
            #expect(watch.$episode.id == nil)
            #expect(watch.watchedOn == "2024-01-01")
        }
    }

    @Test func movieFallbackFallsBackToShow() async throws {
        let tmdb = Self.fake()
        tmdb.setSearch("tv", "Pokémon", [TMDBSearchResult(id: 60572, kind: .tv, name: "Pokémon", originalName: nil, year: 1997, posterPath: nil)])
        tmdb.addSeries(TMDBSeries(id: 60572, name: "Pokémon", originalName: nil, year: 1997, posterPath: nil, status: "Returning Series", seasonNumbers: [1]),
                       episodes: [1: ["Ich wähle dich", "Pika-Pikachu"]], airDate: "1998-01-01")
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let row = try #require(try await rows(app, user, containing: "Pika-Pikachu").first)
            #expect(row.rowStatus == .matched)
            let leftover = try await NetflixMapping.query(on: app.db).filter(\.$netflixName == "Pokémon: Pika-Pikachu").count()
            #expect(leftover == 0)
        }
    }

    @Test func tmdbFailureKeepsRowsPending() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let w = worker(app, tmdb)
            tmdb.failure = .unauthorized
            _ = try await w.processAll()
            let all = try await NetflixRow.query(on: app.db).all()
            #expect(all.allSatisfy { $0.rowStatus == .pending })
            #expect(await w.lastError?.hasPrefix("TMDB nicht erreichbar") == true)
            tmdb.failure = nil
            _ = try await w.processAll()
            #expect(try await rows(app, user, containing: "The Mentalist").allSatisfy { $0.rowStatus == .matched })
            #expect(await w.lastError == nil)
        }
    }

    @Test func mappingsReusedAcrossImports() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let w = worker(app, tmdb)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await w.processAll()
            _ = try await ImportService(db: app.db).ingest(text: "Title,Date\n\"The Mentalist: Staffel 4: Scharlachrote Briefe\",\"11/1/26\"\n",
                                                          filename: "b.csv", userID: user.requireID())
            _ = try await w.processAll()
            #expect(tmdb.calls.filter { $0 == "search:tv:The Mentalist" }.count == 1)
            #expect(try await rows(app, user, containing: "Scharlachrote").first?.rowStatus == .matched)
        }
    }

    @Test func restartRecovery() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = worker(app, tmdb)   // never ran (simulated crash)
            _ = try await worker(app, tmdb).processAll()
            #expect(try await rows(app, user, containing: "The Mentalist").allSatisfy { $0.rowStatus == .matched })
        }
    }
}
