@testable import App
import Testing
import VaporTesting

@Suite("Config")
struct ConfigTests {
    @Test func defaults() throws {
        let c = try AppConfig.fromEnvironment([:])
        #expect(c.tmdbLanguage == "de-DE")
        #expect(c.databasePath == "/data/watchswifty.sqlite")
        #expect(c.host == "0.0.0.0")
        #expect(c.port == 8080)
        #expect(c.adminUsername == nil)
        #expect(c.adminPassword == nil)
        #expect(c.backgroundJobsEnabled)
    }

    @Test func overrides() throws {
        let c = try AppConfig.fromEnvironment([
            "TMDB_LANGUAGE": "en-US", "DATABASE_PATH": "/tmp/x.sqlite",
            "HOST": "127.0.0.1", "PORT": "9000", "ADMIN_USERNAME": "pat", "ADMIN_PASSWORD": "secret123",
        ])
        #expect(c.tmdbLanguage == "en-US")
        #expect(c.databasePath == "/tmp/x.sqlite")
        #expect(c.host == "127.0.0.1")
        #expect(c.port == 9000)
        #expect(c.adminUsername == "pat")
        #expect(c.adminPassword == "secret123")
    }

    @Test func healthz() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/healthz") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            }
        }
    }
}
