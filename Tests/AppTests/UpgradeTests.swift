@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Upgrades databases written by released versions with today's migrations and checks that the data survives and the
/// app works on it. The fixtures are generated with the code of the release itself (`scripts/upgrade-fixtures/`, see
/// `docs/development.md`), so they hold exactly what that version wrote.
@Suite("Upgrade")
struct UpgradeTests {
    /// The `TOKEN_KEY` the fixtures were written with.
    static let fixtureTokenKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="

    /// Copies the fixture of `version` to a temporary file and runs `test` on an app configured with it.
    func withUpgradedApp(from version: String, _ test: (Application) async throws -> Void) async throws {
        let fixture = try #require(Bundle.module.url(forResource: version, withExtension: "sqlite",
                                                     subdirectory: "Fixtures/upgrade"))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchswifty-upgrade-\(UUID().uuidString).sqlite").path
        try FileManager.default.copyItem(atPath: fixture.path, toPath: path)
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        var config = AppConfig.testing
        config.databasePath = path
        config.tokenKey = Self.fixtureTokenKey
        try await withTestApp(config: config, test)
    }

    @Test func v010MigratesCompletely() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            #expect(try await app.migrator.previewPrepareBatch().get().isEmpty)
            // Every model decodes every row; new nullable columns must not break old rows.
            #expect(try await User.query(on: app.db).count() == 3)
            #expect(try await Title.query(on: app.db).all().count == 4)
            #expect(try await Episode.query(on: app.db).all().count == 11)
            #expect(try await UserTitle.query(on: app.db).all().count == 6)
            #expect(try await Watch.query(on: app.db).all().count == 14)
            #expect(try await SeasonNote.query(on: app.db).all().count == 1)
            #expect(try await NetflixImport.query(on: app.db).all().count == 1)
            #expect(try await NetflixMapping.query(on: app.db).all().count == 14)
            #expect(try await NetflixRow.query(on: app.db).all().count == 19)
            _ = try await User.query(on: app.db).all()
            _ = try await AppSettings.query(on: app.db).all()
            // The stock session table is emptied by `CreateWebSession`: everyone logs in again once.
            #expect(try await SessionRecord.query(on: app.db).count() == 0)
        }
    }

    @Test func v010BackfillsNewColumns() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            let titles = try await Title.query(on: app.db).all()
            let refreshed = Dictionary(uniqueKeysWithValues: titles.map { ($0.id!, $0.refreshedAt) })
            for episode in try await Episode.query(on: app.db).all() {
                #expect(episode.lastSeenAt != nil)
                #expect(episode.lastSeenAt == refreshed[episode.$title.id] ?? nil)
            }
            let withCandidates = try await NetflixMapping.query(on: app.db).filter(\.$candidates != nil).all()
            #expect(!withCandidates.isEmpty)
            #expect(withCandidates.allSatisfy { $0.candidatesAt != nil })
        }
    }

    @Test func v010KeepsSecretsAndPasswords() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            let pat = try #require(try await User.query(on: app.db).filter(\.$username == "pat").first())
            #expect(app.tokenCipher.open(pat.tmdbToken) == "fixture-tmdb-token")
            _ = try await login(app, "pat")
            _ = try await login(app, "admin", password: "adminpass123")
        }
    }

    @Test func v010WebPagesRender() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            let pat = try await login(app, "pat")
            let pages: [(String, String?)] = [
                ("/", "Fixture Serie"), ("/library", "Fixture Serie"), ("/history", "Fixture Film"),
                ("/stats", nil), ("/tv/500", "Staffel 1 war gut"), ("/movie/600", "Fixture Film"),
                ("/import", nil), ("/account", nil), ("/watch-later", nil),
            ]
            for (path, text) in pages {
                try await app.testing().test(.GET, path, headers: pat) { res async in
                    #expect(res.status == .ok, "\(path)")
                    if let text { #expect(res.body.string.contains(text), "\(path) should show \(text)") }
                }
            }
            let admin = try await login(app, "admin", password: "adminpass123")
            for path in ["/admin/users", "/admin/system"] {
                try await app.testing().test(.GET, path, headers: admin) { res async in
                    #expect(res.status == .ok, "\(path)")
                }
            }
        }
    }

    @Test func v010APIReadsAndWrites() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            let pat = try #require(try await User.query(on: app.db).filter(\.$username == "pat").first())
            let headers = HTTPHeaders.bearer(try await apiToken(app, pat))
            for path in ["me", "library", "history", "stats", "continue-watching", "tv/500", "movies/600",
                         "imports/netflix", "watch-later", "me/notifications", "me/streaming-services"] {
                try await app.testing().test(.GET, "/api/v1/\(path)", headers: headers) { res async in
                    #expect(res.status == .ok, "/api/v1/\(path): \(res.body.string)")
                }
            }
            try await app.testing().test(.GET, "/api/v1/continue-watching", headers: headers) { res async in
                #expect(res.body.string.contains("Fixture Serie"), "\(res.body.string)")
                #expect(res.body.string.contains("Folge 1x3"), "next episode is 1x3: \(res.body.string)")
            }
            try await app.testing().test(.POST, "/api/v1/tv/500/episodes/1/3/watch", headers: headers,
                                         beforeRequest: { req in
                try req.content.encode(["day": "2026-11-07", "service": "netflix"], as: .json)
            }) { res async in
                #expect(res.status == .ok, "\(res.body.string)")
            }
            #expect(try await Watch.query(on: app.db).count() == 15)
        }
    }

    @Test func v010KeepsUsersApart() async throws {
        try await withUpgradedApp(from: "v0.1.0") { app in
            let kim = try #require(try await User.query(on: app.db).filter(\.$username == "kim").first())
            let headers = HTTPHeaders.bearer(try await apiToken(app, kim))
            try await app.testing().test(.GET, "/api/v1/tv/500", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("Staffel 1 war gut"))
            }
            try await app.testing().test(.GET, "/api/v1/imports/netflix", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("The Mentalist"))
            }
        }
    }
}
