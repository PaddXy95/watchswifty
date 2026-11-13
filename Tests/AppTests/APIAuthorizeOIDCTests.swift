@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("APIAuthorizeOIDC")
struct APIAuthorizeOIDCTests {
    let challenge = pkceChallenge("verifier-verifier-verifier-verifier-verifier")

    private var authorizePath: String {
        var components = URLComponents(string: "/api/auth/authorize")!
        components.queryItems = [
            .init(name: "redirect_uri", value: "dev.patmei.watchswifty:/auth"), .init(name: "state", value: "xyz"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "device_name", value: "Phone"),
        ]
        return components.string!
    }

    /// An SSO-only account signed in through the provider.
    private func signedInSSOUser(_ app: Application, _ fake: FakeOIDCProvider) async throws -> HTTPHeaders {
        let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
        try await user.save(on: app.db)
        try await linkOIDC(app, user)
        let flow = try await oidcFlow(app, fake)
        #expect(flow.location == "/")
        return flow.headers
    }

    private func decide(_ app: Application, headers: HTTPHeaders) async throws -> OIDCFlowResult {
        try await browserPost(app, "/api/auth/authorize", form: [
            "redirect_uri": "dev.patmei.watchswifty:/auth", "state": "xyz", "code_challenge": challenge,
            "code_challenge_method": "S256", "device_name": "Phone", "decision": "connect",
        ], headers: headers)
    }

    @Test func ssoAccountMustReauthenticate() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let headers = try await signedInSSOUser(app, fake)
            let page = try await browserGet(app, authorizePath, headers: headers)
            #expect(page.status == .seeOther)
            #expect(page.location == "/auth/oidc/start?returnTo=" + formEncode(authorizePath))
        }
    }

    @Test func reauthWithSameIdentityShowsConnect() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let headers = try await signedInSSOUser(app, fake)
            let redirect = try await browserGet(app, authorizePath, headers: headers)
            let reauth = try await oidcFlow(app, fake, start: try #require(redirect.location), headers: redirect.headers)
            #expect(reauth.location == authorizePath)
            let page = try await browserGet(app, authorizePath, headers: reauth.headers)
            #expect(page.status == .ok)
            #expect(page.body.contains("Verbinden"))
            let decided = try await decide(app, headers: reauth.headers)
            #expect(decided.location?.hasPrefix("dev.patmei.watchswifty:/auth?code=") == true)
        }
    }

    @Test func reauthWithOtherIdentityFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let headers = try await signedInSSOUser(app, fake)
            let redirect = try await browserGet(app, authorizePath, headers: headers)
            fake.identity = oidcIdentity("someone-else")
            let reauth = try await oidcFlow(app, fake, start: try #require(redirect.location), headers: redirect.headers)
            #expect(reauth.status == .forbidden)
            #expect(reauth.body.contains("Bei SSO ist ein anderes Konto angemeldet."))
            let again = try await browserGet(app, authorizePath, headers: reauth.headers)
            #expect(again.status == .seeOther)
            #expect(again.location?.hasPrefix("/auth/oidc/start") == true)
        }
    }

    @Test func decideWithoutFreshReauthIssuesNoCode() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let headers = try await signedInSSOUser(app, fake)
            let decided = try await decide(app, headers: headers)
            #expect(decided.status == .seeOther)
            #expect(decided.location == "/auth/oidc/start?returnTo=" + formEncode(authorizePath))
        }
    }

    @Test func reauthExpiresAfterFiveMinutes() {
        #expect(OIDCController.isFresh(verifiedAt: "1800000000", now: Date(timeIntervalSince1970: 1_800_000_300)))
        #expect(!OIDCController.isFresh(verifiedAt: "1800000000", now: Date(timeIntervalSince1970: 1_800_000_301)))
        #expect(!OIDCController.isFresh(verifiedAt: nil, now: Date()))
        #expect(!OIDCController.isFresh(verifiedAt: "garbage", now: Date()))
    }

    @Test func passwordAccountNeedsNoReauth() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let headers = try await login(app, "anna")
            let page = try await browserGet(app, authorizePath, headers: headers)
            #expect(page.status == .ok)
            #expect(page.body.contains("Verbinden"))
        }
    }

    @Test func passwordAccountNotRedirectedToCanonical() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            try await createUser(app, "anna")
            var headers = try await login(app, "anna")
            headers.replaceOrAdd(name: .host, value: "other.lan:8080")
            let page = try await browserGet(app, authorizePath, headers: headers)
            #expect(page.status == .ok)
        }
    }

    @Test func anonymousOnOtherHostRedirectsToCanonical() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let page = try await browserGet(app, authorizePath, headers: ["Host": "other.lan:8080"])
            #expect(page.status == .seeOther)
            #expect(page.location == "http://localhost:8080" + authorizePath + "&oidc_c=1")
            let again = try await browserGet(app, authorizePath + "&oidc_c=1", headers: ["Host": "other.lan:8080"])
            #expect(again.status == .seeOther)
            #expect(again.location?.hasPrefix("/login?returnTo=") == true)
        }
    }

    @Test func ssoAccountOnPasswordLoginOffIncludesAccountsWithPassword() async throws {
        let fake = FakeOIDCProvider()
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let flow = try await oidcFlow(app, fake)
            let page = try await browserGet(app, authorizePath, headers: flow.headers)
            #expect(page.status == .seeOther)
            #expect(page.location?.hasPrefix("/auth/oidc/start") == true)
        }
    }

    @Test func ssoAccountManualTokenNeedsReauth() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let headers = try await signedInSSOUser(app, fake)
            let refused = try await browserPost(app, "/account/devices", form: ["name": "Skript"], headers: headers)
            #expect(refused.status == .forbidden)
            #expect(refused.body.contains("Bitte zuerst über SSO bestätigen – danach das Token erstellen."))
            #expect(refused.body.contains("action=\"/account/oidc/reauth\""))
            #expect(try await APIToken.query(on: app.db).count() == 0)

            let reauth = try await browserPost(app, "/account/oidc/reauth", form: [:], headers: headers)
            #expect(reauth.location == "/auth/oidc/start")
            let back = try await oidcFlow(app, fake, start: try #require(reauth.location), headers: reauth.headers)
            #expect(back.location == "/account?open=devices")
            let created = try await browserPost(app, "/account/devices", form: ["name": "Skript"], headers: back.headers)
            #expect(created.status == .ok)
            #expect(try await APIToken.query(on: app.db).count() == 1)
        }
    }

    @Test func passwordAccountManualTokenNeedsNoReauth() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let created = try await browserPost(app, "/account/devices", form: ["name": "Skript"], headers: try await login(app, "anna"))
            #expect(created.status == .ok)
        }
    }
}
