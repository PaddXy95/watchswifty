@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AvailabilityPass")
struct AvailabilityPassTests {
    static let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func list(_ app: Application, _ user: User, _ title: Title) async throws {
        try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(), addedAt: start, addedOn: "2026-11-07",
                                  baselined: true).save(on: app.db)
    }

    func pass(_ app: Application, now: Date) async -> AvailabilityPassResult {
        await refreshWatchLaterAvailability(db: app.db, provider: app.tmdbProvider, cipher: app.tokenCipher, logger: app.logger, now: now)
    }

    @Test func passFetchesEachListTitleOnce() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            let pat = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("t1"))
            pat.notifyAvailable = true
            try await pat.save(on: app.db)
            try await UserStreamingService(userID: pat.requireID(), providerID: 8).save(on: app.db)
            let sepp = try await createUser(app, "sepp", tmdbToken: try app.tokenCipher.seal("t2"))
            let movie = try await seedMovie(app, tmdbID: 603)
            _ = try await seedMovie(app, tmdbID: 604)
            try await list(app, pat, movie)
            try await list(app, sepp, movie)

            #expect(await pass(app, now: start) == AvailabilityPassResult(refreshed: 1))
            #expect(tmdb.calls == ["watch_providers:movie:603"])
            #expect(try await AvailabilityNotice.query(on: app.db).first()?.noticeState == .pending)
        }
    }

    @Test func passSkipsTitleWithoutToken() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let pat = try await createUser(app, "pat", tmdbToken: nil)
            try await list(app, pat, try await seedMovie(app, tmdbID: 603))
            #expect(await pass(app, now: start) == AvailabilityPassResult())
            #expect(tmdb.calls.isEmpty)
        }
    }

    @Test func passCountsFailures() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.fail("watch_providers:movie:603", with: .notFound)
        try await withTestApp(tmdb: tmdb) { app in
            let pat = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("t1"))
            try await list(app, pat, try await seedMovie(app, tmdbID: 603))
            #expect(await pass(app, now: start) == AvailabilityPassResult(failed: 1))
        }
    }

    @Test func passExpiresOldData() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let old = try await seedMovie(app, tmdbID: 605)   // not on any list: not fetched again
            try await AvailabilityService(db: app.db).refresh(old, tmdb: tmdb, now: start)
            #expect(await pass(app, now: start.addingTimeInterval(31 * Self.day)) == AvailabilityPassResult(expired: 1))
        }
    }
}
