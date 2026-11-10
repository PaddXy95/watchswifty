@testable import App
import Foundation
import Testing

@Suite("OIDCConfig")
struct OIDCConfigTests {
    private let base = [
        "OIDC_ISSUER": "https://id.example.de/application/o/watchswifty/",
        "OIDC_CLIENT_ID": "watchswifty",
        "OIDC_CLIENT_SECRET": "secret",
        "PUBLIC_ORIGIN": "https://watch.example.de",
    ]

    @Test func completeConfigEnablesOIDC() throws {
        let config = try AppConfig.fromEnvironment(base)
        let oidc = try #require(config.oidc)
        #expect(oidc.displayName == "SSO")
        #expect(oidc.issuer == "https://id.example.de/application/o/watchswifty/")
        #expect(oidc.clientID == "watchswifty")
        #expect(oidc.clientSecret == "secret")
        #expect(oidc.redirectURL.absoluteString == "https://watch.example.de/auth/oidc/callback")
        #expect(oidc.canonicalOrigin == "https://watch.example.de")
        #expect(config.passwordLogin)
    }

    @Test func noOIDCVariablesMeansNoOIDC() throws {
        let config = try AppConfig.fromEnvironment(["PUBLIC_ORIGIN": "https://watch.example.de"])
        #expect(config.oidc == nil)
        #expect(config.passwordLogin)
    }

    @Test func displayNameFromEnvironment() throws {
        var env = base
        env["OIDC_NAME"] = "Pocket ID"
        #expect(try AppConfig.fromEnvironment(env).oidc?.displayName == "Pocket ID")
    }

    @Test func partialConfigFails() {
        #expect(throws: ConfigError.self) {
            try AppConfig.fromEnvironment(["OIDC_ISSUER": "https://id.example.de", "PUBLIC_ORIGIN": "https://watch.example.de"])
        }
        #expect(throws: ConfigError.self) {
            try AppConfig.fromEnvironment(["OIDC_CLIENT_ID": "x", "OIDC_CLIENT_SECRET": "y", "PUBLIC_ORIGIN": "https://w.example.de"])
        }
    }

    @Test func explicitRedirectWins() throws {
        var env = base
        env["OIDC_REDIRECT_URL"] = "https://w.example.de/auth/oidc/callback"
        let oidc = try #require(try AppConfig.fromEnvironment(env).oidc)
        #expect(oidc.redirectURL.absoluteString == "https://w.example.de/auth/oidc/callback")
        #expect(oidc.canonicalOrigin == "https://w.example.de")
    }

    @Test func canonicalOriginKeepsPort() throws {
        var env = base
        env["PUBLIC_ORIGIN"] = "https://nas.lan:8443/,https://other.lan"
        let oidc = try #require(try AppConfig.fromEnvironment(env).oidc)
        #expect(oidc.redirectURL.absoluteString == "https://nas.lan:8443/auth/oidc/callback")
        #expect(oidc.canonicalOrigin == "https://nas.lan:8443")
    }

    @Test func missingRedirectAndOriginFails() {
        var env = base
        env["PUBLIC_ORIGIN"] = nil
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment(env) }
    }

    @Test func invalidRedirectFails() {
        var env = base
        env["OIDC_REDIRECT_URL"] = "not a url"
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment(env) }
    }

    @Test func secretFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oidc-secret-\(UUID().uuidString)")
        try Data("s3cret\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var env = base
        env["OIDC_CLIENT_SECRET"] = nil
        env["OIDC_CLIENT_SECRET_FILE"] = url.path
        #expect(try AppConfig.fromEnvironment(env).oidc?.clientSecret == "s3cret")
    }

    @Test func unreadableSecretFileFails() {
        var env = base
        env["OIDC_CLIENT_SECRET"] = nil
        env["OIDC_CLIENT_SECRET_FILE"] = "/nonexistent/oidc-secret"
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment(env) }
    }

    @Test func passwordLoginOffWithoutOIDCFails() throws {
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment(["PASSWORD_LOGIN": "false"]) }
        var env = base
        env["PASSWORD_LOGIN"] = "FALSE"
        #expect(try AppConfig.fromEnvironment(env).passwordLogin == false)
        env["PASSWORD_LOGIN"] = "true"
        #expect(try AppConfig.fromEnvironment(env).passwordLogin)
    }

    @Test func issuerMatchIgnoresTrailingSlash() throws {
        let oidc = try #require(try AppConfig.fromEnvironment(base).oidc)
        #expect(oidc.matchesIssuer("https://id.example.de/application/o/watchswifty"))
        #expect(oidc.matchesIssuer("https://id.example.de/application/o/watchswifty/"))
        #expect(!oidc.matchesIssuer(nil))
        #expect(!oidc.matchesIssuer("https://other.example.de/"))
    }

    @Test func testingOIDCConfig() throws {
        let oidc = try #require(AppConfig.testingOIDC.oidc)
        #expect(oidc.canonicalOrigin == "http://localhost:8080")
        #expect(oidc.issuer == "https://id.example.test")
    }
}
