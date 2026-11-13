@testable import App
import Elementary
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@Suite("CatalogMaintenance")
struct CatalogMaintenanceTests {
    static let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Fake TMDB plus a provider that records which token each client was made for.
    static func setup() -> (FakeTMDBClient, TMDBProvider, NIOLockedValueBox<[String]>) {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, overview: "Neu.", runtime: 136))
        tmdb.addMovie(TMDBMovie(id: 604, name: "Heat", originalName: nil, year: 1995, posterPath: nil, overview: "Neu.", runtime: 170))
        tmdb.addMovie(TMDBMovie(id: 605, name: "Alien", originalName: nil, year: 1979, posterPath: nil, overview: "Neu.", runtime: 117))
        let tokens = NIOLockedValueBox<[String]>([])
        let provider = TMDBProvider { token in
            tokens.withLockedValue { $0.append(token) }
            return tmdb
        }
        return (tmdb, provider, tokens)
    }

    func movie(_ app: Application, _ tmdbID: Int, refreshedAt: Date) async throws -> Title {
        let title = try await seedMovie(app, tmdbID: tmdbID, runtime: 100)
        title.overview = "Alt."
        title.imdbID = "tt1"
        title.genres = "drama"
        title.refreshedAt = refreshedAt
        try await title.save(on: app.db)
        return title
    }

    func watch(_ app: Application, _ user: User, _ title: Title) async throws {
        try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: nil, watchedOn: "2026-01-01",
                        service: nil, origin: .manual).save(on: app.db)
    }

    func maintain(_ app: Application, _ provider: TMDBProvider, at now: Date, limit: Int = 200) async -> MaintenanceResult {
        await maintainCatalog(db: app.db, provider: provider, cipher: app.tokenCipher, logger: app.logger, now: now, refreshLimit: limit)
    }

    @Test func staleTitleRefreshedWithOwnersToken() async throws {
        let (_, provider, tokens) = Self.setup()
        try await withTestApp { app in
            _ = try await createUser(app, "fremd", tmdbToken: "stranger-token")
            let owner = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("owner-token"))
            let title = try await movie(app, 603, refreshedAt: start)
            try await watch(app, owner, title)

            let now = start.addingTimeInterval(61 * Self.day)
            #expect(await maintain(app, provider, at: now) == MaintenanceResult(refreshed: 1))
            #expect(tokens.withLockedValue { $0 } == ["owner-token"])
            let reloaded = try #require(try await Title.find(title.requireID(), on: app.db))
            #expect(reloaded.overview == "Neu.")
            #expect(reloaded.refreshedAt.map { abs($0.timeIntervalSince(now)) < 1 } == true)
        }
    }

    @Test func freshTitleUntouched() async throws {
        let (_, provider, tokens) = Self.setup()
        try await withTestApp { app in
            let owner = try await createUser(app, "pat")
            try await watch(app, owner, try await movie(app, 603, refreshedAt: start))
            #expect(await maintain(app, provider, at: start.addingTimeInterval(59 * Self.day)) == MaintenanceResult())
            #expect(tokens.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func unusedStaleTitleDeleted() async throws {
        let (_, provider, tokens) = Self.setup()
        try await withTestApp { app in
            _ = try await createUser(app, "pat")
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            series.refreshedAt = start
            try await series.save(on: app.db)
            #expect(await maintain(app, provider, at: start.addingTimeInterval(61 * Self.day)) == MaintenanceResult(deleted: 1))
            #expect(try await Title.query(on: app.db).count() == 0)
            #expect(try await Episode.query(on: app.db).count() == 0)
            #expect(tokens.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func noOwnerTokenClearsOnlyAfterSixMonths() async throws {
        let (_, provider, tokens) = Self.setup()
        try await withTestApp { app in
            _ = try await createUser(app, "fremd", tmdbToken: "stranger-token")   // never used for others' titles
            let owner = try await createUser(app, "pat", tmdbToken: nil)
            let title = try await movie(app, 603, refreshedAt: start)
            try await watch(app, owner, title)

            #expect(await maintain(app, provider, at: start.addingTimeInterval(100 * Self.day)) == MaintenanceResult())
            #expect(try await Title.find(title.requireID(), on: app.db)?.overview == "Alt.")

            #expect(await maintain(app, provider, at: start.addingTimeInterval(181 * Self.day)) == MaintenanceResult(cleared: 1))
            let cleared = try #require(try await Title.find(title.requireID(), on: app.db))
            #expect(cleared.overview == nil)
            #expect(cleared.imdbID == nil)
            #expect(cleared.runtime == nil)
            #expect(cleared.genres == nil)
            #expect(cleared.name == "Film")   // kept for the user's history
            #expect(tokens.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func refreshLimitPerPass() async throws {
        let (_, provider, _) = Self.setup()
        try await withTestApp { app in
            let owner = try await createUser(app, "pat")
            for (offset, id) in [603, 604, 605].enumerated() {
                try await watch(app, owner, try await movie(app, id, refreshedAt: start.addingTimeInterval(Double(offset) * Self.day)))
            }
            let now = start.addingTimeInterval(70 * Self.day)
            #expect(await maintain(app, provider, at: now, limit: 2) == MaintenanceResult(refreshed: 2))
            let stillOld = try await Title.query(on: app.db).all().filter { ($0.refreshedAt ?? .distantPast) < now.addingTimeInterval(-60 * Self.day) }
            #expect(stillOld.map(\.tmdbID) == [605])   // the oldest ones went first
        }
    }

    @Test func staleCandidatesCleared() async throws {
        let (_, provider, _) = Self.setup()
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let candidate = TMDBSearchResult(id: 1, kind: .tv, name: "X", originalName: nil, year: 2020, posterPath: nil)
            let mapping = NetflixMapping(userID: try user.requireID(), netflixName: "X", kind: .tv)
            mapping.candidateResults = [candidate]
            try await mapping.save(on: app.db)
            try await FilmListService(db: app.db).replace(userID: user.requireID(), drafts: [
                FilmListDraft(title: "Y", year: 2020, watches: [FilmWatch(day: nil, service: nil)], rating: nil, comment: nil),
            ])
            let entry = try #require(try await FilmListEntry.query(on: app.db).first())
            entry.setCandidates([candidate])
            try await entry.save(on: app.db)

            #expect(await maintain(app, provider, at: Date().addingTimeInterval(59 * Self.day)).candidatesCleared == 0)
            #expect(await maintain(app, provider, at: Date().addingTimeInterval(61 * Self.day)).candidatesCleared == 2)
            #expect(try await NetflixMapping.find(mapping.requireID(), on: app.db)?.candidates == nil)
            #expect(try await FilmListEntry.find(entry.requireID(), on: app.db)?.candidates == nil)
        }
    }
}

@Suite("TMDBAttribution")
struct TMDBAttributionTests {
    @Test func footerShowsTMDBAttribution() {
        let html = PageLayout(title: "X", nav: nil) { p { "x" } }.render()
        #expect(html.contains(#"src="/img/tmdb-logo.svg""#))
        #expect(html.contains(#"alt="TMDB""#))
        #expect(html.contains(#"href="https://www.themoviedb.org""#))
        #expect(html.contains("Diese Anwendung verwendet TMDB und die TMDB-APIs, ist aber nicht von TMDB unterstützt, zertifiziert oder anderweitig genehmigt."))
        #expect(!html.contains(#"href="https://github.com/PaddXy95/watchswifty""#))
    }
}
