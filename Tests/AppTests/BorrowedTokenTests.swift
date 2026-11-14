@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Background work on a shared title borrows a user's TMDB token. One user's rejected token must not block the
/// title for everyone else: other users still match from the cache, and refreshes fall back to another owner's
/// token (security audit F13). "aaron" sorts first by id and by name, so he is always asked first.
@Suite("BorrowedTokens")
struct BorrowedTokenTests {
    static let seriesID = 500

    func owner(_ app: Application, _ name: String, id: String, token: String) async throws -> User {
        let user = User(username: name, passwordHash: "x", isAdmin: false)
        user.id = UUID(uuidString: id)!
        user.tmdbToken = token
        try await user.create(on: app.db)
        return user
    }

    func aaron(_ app: Application) async throws -> User {
        try await owner(app, "aaron", id: "00000000-0000-0000-0000-000000000001", token: "aaron-token")
    }

    func zoe(_ app: Application) async throws -> User {
        try await owner(app, "zoe", id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", token: "zoe-token")
    }

    /// TMDB rejects aaron's token; for everyone else it knows the series with one more episode than the cache.
    static func provider() -> TMDBProvider {
        let good = FakeTMDBClient()
        good.addSeries(TMDBSeries(id: seriesID, name: "Serie", originalName: nil, year: 2020, posterPath: nil,
                                  status: "Returning Series", seasonNumbers: [1]),
                       episodes: [1: ["Folge 1x1", "Folge 1x2", "Folge 1x3", "Neue Folge"]])
        let rejecting = FakeTMDBClient()
        rejecting.failure = .unauthorized
        return TMDBProvider { $0 == "aaron-token" ? rejecting : good }
    }

    /// The cached series (3 episodes), last refreshed `age` seconds ago.
    func cachedSeries(_ app: Application, age: TimeInterval) async throws -> Title {
        let show = try await seedSeries(app, tmdbID: Self.seriesID, seasons: [1: 3])
        show.refreshedAt = Date().addingTimeInterval(-age)
        try await show.save(on: app.db)
        return show
    }

    func episodeCount(_ app: Application, _ show: Title) async throws -> Int {
        try await Episode.query(on: app.db).filter(\.$title.$id == show.requireID()).count()
    }

    /// Netflix rows of `user` (Netflix name → row titles), each name confirmed to `show`.
    func confirmedRows(_ app: Application, _ user: User, _ show: Title, _ names: [String: [String]]) async throws {
        let userID = try user.requireID()
        let csv = "Title,Date\n" + names.values.flatMap { $0 }.map { "\($0),11/1/26" }.joined(separator: "\n")
        _ = try await ImportService(db: app.db).ingest(text: csv, filename: "a.csv", userID: userID)
        for (name, titles) in names {
            let mapping = NetflixMapping(userID: userID, netflixName: name, kind: .tv)
            mapping.status = MappingStatus.confirmed.rawValue
            mapping.$title.id = try show.requireID()
            try await mapping.save(on: app.db)
            try await NetflixRow.query(on: app.db).filter(\.$user.$id == userID).filter(\.$rawTitle ~~ titles)
                .set(\.$mapping.$id, to: mapping.requireID()).update()
        }
    }

    @Test func otherUsersMatchDespiteRejectedRefresh() async throws {
        try await withTestApp { app in
            let show = try await cachedSeries(app, age: 2 * 3600)
            let aaron = try await aaron(app)
            let zoe = try await zoe(app)
            let fakes = Dictionary(uniqueKeysWithValues: (1...20).map { ("Fake \($0)", ["Fake \($0): Staffel 1: Zzqx \($0)"]) })
            try await confirmedRows(app, aaron, show, fakes)
            // One row matches the cached episodes, one needs the refresh with zoe's own token.
            try await confirmedRows(app, zoe, show, ["Serie": ["Serie: Staffel 1: Folge 1x2", "Serie: Staffel 1: Neue Folge"]])

            let worker = MatchingWorker(db: app.db, provider: Self.provider(), logger: app.logger, cipher: app.tokenCipher, enabled: false)
            _ = try await worker.processAll()

            let zoeRows = try await NetflixRow.query(on: app.db).filter(\.$user.$id == zoe.requireID()).all()
            #expect(zoeRows.map(\.rowStatus) == [.matched, .matched])
            #expect(await worker.lastError(for: try zoe.requireID()) == nil)
            // aaron's junk rows never match: pending after his own failed refresh, or unmatched when zoe refreshed first.
            let aaronRows = try await NetflixRow.query(on: app.db).filter(\.$user.$id == aaron.requireID()).all()
            #expect(aaronRows.allSatisfy { $0.rowStatus != .matched })
        }
    }

    @Test func dailyRefreshTriesTheNextOwner() async throws {
        try await withTestApp { app in
            app.tmdbProvider = Self.provider()
            let show = try await cachedSeries(app, age: 0)
            for user in [try await aaron(app), try await zoe(app)] {
                try await WatchService(db: app.db).setFollowed(userID: user.requireID(), titleID: show.requireID(), followed: true)
            }
            await runDailyPass(app)
            #expect(try await episodeCount(app, show) == 4)
        }
    }

    @Test func cacheMaintenanceTriesTheNextOwner() async throws {
        try await withTestApp { app in
            let show = try await cachedSeries(app, age: 61 * 86_400)
            for user in [try await aaron(app), try await zoe(app)] {
                try await WatchService(db: app.db).setFollowed(userID: user.requireID(), titleID: show.requireID(), followed: true)
            }
            let result = await maintainCatalog(db: app.db, provider: Self.provider(), cipher: app.tokenCipher, logger: app.logger)
            #expect(result.refreshed == 1)
            #expect(try await episodeCount(app, show) == 4)
        }
    }

    @Test func detailBackfillTriesTheNextWatcher() async throws {
        try await withTestApp { app in
            let show = try await cachedSeries(app, age: 0)
            show.genres = nil
            try await show.save(on: app.db)
            for user in [try await aaron(app), try await zoe(app)] {
                _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                                   day: "2026-11-01", service: nil)
            }
            let filled = await backfillDetails(db: app.db, provider: Self.provider(), cipher: app.tokenCipher, logger: app.logger)
            #expect(filled == 1)
            #expect(try await episodeCount(app, show) == 4)
        }
    }
}
