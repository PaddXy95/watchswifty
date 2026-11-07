@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("StaleCache")
struct StaleCacheTests {
    static let newRow = "Title,Date\n\"The Mentalist: Staffel 5: Neue Folge\",\"11/7/26\"\n"

    /// Caches title 1001 (seasons 1 and 4), then makes TMDB know a season 5.
    func prepare(_ app: Application, _ tmdb: FakeTMDBClient, cacheAge: TimeInterval) async throws -> Title {
        let title = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 1001)
        title.refreshedAt = Date().addingTimeInterval(-cacheAge)
        try await title.save(on: app.db)
        tmdb.addSeries(TMDBSeries(id: 1001, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4, 5]),
                       episodes: [1: ["Pilot"], 4: ["Scharlachrote Briefe", "Die Aura des Todes", "Keine Lust auf Shakespeare"], 5: ["Neue Folge"]],
                       airDate: "2011-01-01")
        return title
    }

    func worker(_ app: Application, _ tmdb: FakeTMDBClient) -> MatchingWorker {
        MatchingWorker(db: app.db, provider: TMDBProvider { _ in tmdb }, logger: app.logger, enabled: false)
    }

    @Test func staleCacheIsRefreshedWhenRowsDoNotMatch() async throws {
        let tmdb = MatchingWorkerTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await prepare(app, tmdb, cacheAge: 2 * 86_400)
            _ = try await ImportService(db: app.db).ingest(text: Self.newRow, filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            let row = try #require(try await NetflixRow.query(on: app.db).first())
            #expect(row.rowStatus == .matched)
        }
    }

    @Test func freshCacheIsNotRefreshed() async throws {
        let tmdb = MatchingWorkerTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await prepare(app, tmdb, cacheAge: 60)
            let seriesCallsBefore = tmdb.calls.filter { $0 == "series:1001" }.count
            _ = try await ImportService(db: app.db).ingest(text: Self.newRow, filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            #expect(tmdb.calls.filter { $0 == "series:1001" }.count == seriesCallsBefore)
            #expect(try await NetflixRow.query(on: app.db).first()?.rowStatus == .unmatched)
        }
    }

    @Test func refreshFailureKeepsRowsPending() async throws {
        let tmdb = MatchingWorkerTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await prepare(app, tmdb, cacheAge: 2 * 86_400)
            _ = try await ImportService(db: app.db).ingest(text: Self.newRow, filename: "a.csv", userID: user.requireID())
            let w = worker(app, tmdb)
            // Resolve the mapping first, then let TMDB fail for the refresh.
            let mapping = NetflixMapping(userID: try user.requireID(), netflixName: "The Mentalist", kind: .tv)
            mapping.$title.id = try await Title.query(on: app.db).filter(\.$tmdbID == 1001).first()?.requireID()
            mapping.status = MappingStatus.auto.rawValue
            try await mapping.save(on: app.db)
            tmdb.failure = .network("down")
            _ = try await w.processAll()
            #expect(try await NetflixRow.query(on: app.db).first()?.rowStatus == .pending)
            #expect(try await w.lastError(for: user.requireID())?.hasPrefix("TMDB nicht erreichbar") == true)
        }
    }

    @Test func requeueUnmatchedRowsOfTitle() async throws {
        let tmdb = MatchingWorkerTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let title = try await prepare(app, tmdb, cacheAge: 60)
            _ = try await ImportService(db: app.db).ingest(text: Self.newRow, filename: "a.csv", userID: user.requireID())
            _ = try await worker(app, tmdb).processAll()
            #expect(try await NetflixRow.query(on: app.db).first()?.rowStatus == .unmatched)
            let count = try await requeueUnmatchedRows(titleID: title.requireID(), on: app.db)
            #expect(count == 1)
            #expect(try await NetflixRow.query(on: app.db).first()?.rowStatus == .pending)
        }
    }
}
