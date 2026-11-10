@testable import App
import Foundation
import Testing

@Suite("OIDCConfig")
struct OIDCConfigTests {
    private let oidc = OIDCConfig(issuer: "https://id.example.de/application/o/watchswifty/", clientID: "watchswifty",
                                  clientSecret: "secret", redirectURL: URL(string: "https://nas.lan:8443/auth/oidc/callback")!)

    @Test func canonicalOriginKeepsPort() {
        #expect(oidc.canonicalOrigin == "https://nas.lan:8443")
        #expect(oidc.displayName == "SSO")
    }

    @Test func issuerMatchIgnoresTrailingSlash() {
        #expect(oidc.matchesIssuer("https://id.example.de/application/o/watchswifty"))
        #expect(oidc.matchesIssuer("https://id.example.de/application/o/watchswifty/"))
        #expect(!oidc.matchesIssuer(nil))
        #expect(!oidc.matchesIssuer("https://other.example.de/"))
    }

    @Test func environmentNoLongerConfiguresOIDC() throws {
        let config = try AppConfig.fromEnvironment([
            "OIDC_ISSUER": "https://id.example.de", "OIDC_CLIENT_ID": "x", "OIDC_CLIENT_SECRET": "y",
            "PUBLIC_ORIGIN": "https://watch.example.de", "PASSWORD_LOGIN": "false",
        ])
        #expect(config.oidc == nil)
        #expect(config.passwordLogin)
        #expect(!config.passwordLoginForced)
    }

    @Test func passwordLoginTrueIsTheEmergencySwitch() throws {
        #expect(try AppConfig.fromEnvironment(["PASSWORD_LOGIN": "true"]).passwordLoginForced)
        #expect(try AppConfig.fromEnvironment(["PASSWORD_LOGIN": "TRUE"]).passwordLoginForced)
        #expect(!(try AppConfig.fromEnvironment([:]).passwordLoginForced))
    }

    @Test func testingOIDCConfig() throws {
        let oidc = try #require(AppConfig.testingOIDC.oidc)
        #expect(oidc.canonicalOrigin == "http://localhost:8080")
        #expect(oidc.issuer == "https://id.example.test")
    }
}
