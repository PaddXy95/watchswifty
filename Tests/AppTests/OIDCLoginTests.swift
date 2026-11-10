@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCLogin")
struct OIDCLoginTests {
    @Test func loginPageShowsSSOButton() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let page = try await browserGet(app, "/login?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1", headers: .sameOrigin)
            #expect(page.body.contains("Mit SSO anmelden"))
            #expect(page.body.contains("/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1"))
            #expect(page.body.contains("name=\"password\""))
        }
    }

    @Test func loginPageWithoutOIDCHasNoButton() async throws {
        try await withTestApp { app in
            let page = try await browserGet(app, "/login", headers: .sameOrigin)
            #expect(!page.body.contains("/auth/oidc/start"))
            let start = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            #expect(start.status == .notFound)
        }
    }

    @Test func startRedirectsToProvider() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            try await app.testing().test(.GET, "/auth/oidc/start", headers: .sameOrigin) { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "https://id.example.test/authorize?state=\(fake.lastState ?? "")")
                let cookie = res.headers.setCookie?[OIDCFlowCookie.name]
                #expect(cookie?.path == "/auth/oidc")
                #expect(cookie?.isHTTPOnly == true)
                #expect(cookie?.isSecure == false)
                #expect((fake.lastState?.count ?? 0) >= 43)
                #expect((fake.lastNonce?.count ?? 0) >= 43)
                #expect(fake.lastChallenge?.count == 43)
            }
        }
    }

    @Test func anonymousStartCreatesNoSession() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let before = try await SessionRecord.query(on: app.db).count()
            let start = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            #expect(start.status == .seeOther)
            #expect(!(start.headers.first(name: .cookie) ?? "").contains("watchswifty_session"))
            #expect(try await SessionRecord.query(on: app.db).count() == before)
        }
    }

    @Test func startOnOtherHostRedirectsToCanonical() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let start = try await browserGet(app, "/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1",
                                             headers: ["Host": "other.lan:8080"])
            #expect(start.status == .seeOther)
            #expect(start.location == "http://localhost:8080/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1")
        }
    }

    @Test func canonicalHostWithoutForwardedProtoDoesNotRedirect() async throws {
        var config = AppConfig.testingOIDC
        config.oidc?.redirectURL = URL(string: "https://localhost:8080/auth/oidc/callback")!
        try await withTestApp(config: config) { app in
            let start = try await browserGet(app, "/auth/oidc/start", headers: ["Host": "localhost:8080"])
            #expect(start.status == .seeOther)
            #expect(start.location?.hasPrefix("https://id.example.test/authorize") == true)
        }
    }

    @Test func startWithUnreachableProviderShowsMessage() async throws {
        let fake = FakeOIDCProvider()
        fake.startError = .unreachable
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let start = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            #expect(start.status == .serviceUnavailable)
            #expect(start.body.contains("SSO ist gerade nicht erreichbar."))
            #expect(start.body.contains("Mit SSO anmelden"))
        }
    }

    @Test func callbackWithoutCookieFails() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            for path in ["/auth/oidc/callback?code=x&state=y", "/auth/oidc/callback?error=access_denied&state=y", "/auth/oidc/callback"] {
                let result = try await browserGet(app, path, headers: .sameOrigin)
                #expect(result.status == .badRequest)
                #expect(result.body.contains("Anmeldung abgelaufen – bitte erneut versuchen."))
            }
        }
    }

    @Test func cookieIsSingleUse() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let started = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            let callback = "/auth/oidc/callback?code=c&state=\(fake.lastState ?? "")"
            let first = try await browserGet(app, callback, headers: started.headers)
            #expect(first.status == .seeOther)
            #expect(first.location == "/")
            // Replaying the old cookie (e.g. second tab) does not work.
            let replay = try await browserGet(app, callback, headers: started.headers.settingCookie("watchswifty_session", nil))
            #expect(replay.status == .badRequest)
            #expect(fake.exchanges.count == 1)
        }
    }

    @Test func clearedCookieAfterCallback() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let result = try await oidcFlow(app, fake)
            #expect(!(result.headers.first(name: .cookie) ?? "").contains(OIDCFlowCookie.name))
        }
    }

    @Test func stateMismatchFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let started = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            let result = try await browserGet(app, "/auth/oidc/callback?code=c&state=forged", headers: started.headers)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Anmeldung abgelaufen"))
            #expect(fake.exchanges.isEmpty)
        }
    }

    @Test func staleCookieFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let old = OIDCFlowCookie(state: "st", nonce: "no", verifier: "ve", startedAt: Date().addingTimeInterval(-601), intent: .login)
            let headers = HTTPHeaders.sameOrigin.settingCookie(OIDCFlowCookie.name, try old.seal(app.tokenCipher))
            let result = try await browserGet(app, "/auth/oidc/callback?code=c&state=st", headers: headers)
            #expect(result.status == .badRequest)
            #expect(fake.exchanges.isEmpty)
        }
    }

    @Test func accessDeniedShowsMessage() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let started = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            let denied = try await browserGet(app, "/auth/oidc/callback?error=access_denied&state=\(fake.lastState ?? "")",
                                              headers: started.headers)
            #expect(denied.status == .forbidden)
            #expect(denied.body.contains("SSO hat die Anmeldung abgelehnt."))

            let again = try await browserGet(app, "/auth/oidc/start", headers: .sameOrigin)
            let other = try await browserGet(app, "/auth/oidc/callback?error=server_error&state=\(fake.lastState ?? "")",
                                             headers: again.headers)
            #expect(other.status == .badRequest)
            #expect(other.body.contains("Anmeldung über SSO fehlgeschlagen."))
        }
    }

    @Test func invalidTokenShowsMessage() async throws {
        let fake = FakeOIDCProvider()
        fake.error = .failed(logReason: "Signatur")
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let result = try await oidcFlow(app, fake)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Anmeldung über SSO fehlgeschlagen."))
        }
    }

    @Test func knownIdentitySignsIn() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user, issuer: OIDCTestKeys.issuer + "/")
            let result = try await oidcFlow(app, fake)
            #expect(result.status == .seeOther)
            #expect(result.location == "/")
            let account = try await browserGet(app, "/account", headers: result.headers)
            #expect(account.status == .ok)
            #expect(account.body.contains("anna"))
        }
    }

    @Test func knownIdentityKeepsSafeReturnTo() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let safe = try await oidcFlow(app, fake, start: "/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1")
            #expect(safe.location == "/api/auth/authorize?x=1")
            let unsafe = try await oidcFlow(app, fake, start: "/auth/oidc/start?returnTo=https%3A%2F%2Fevil.example")
            #expect(unsafe.location == "/")
        }
    }

    @Test func sameSubjectOtherIssuerIsUnknown() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user, issuer: "https://old.example")
            let result = try await oidcFlow(app, fake)
            #expect(result.status == .seeOther)
            #expect(result.location == "/auth/oidc/new-account")
            #expect(!(result.headers.first(name: .cookie) ?? "").contains("watchswifty_session"))
        }
    }
}
