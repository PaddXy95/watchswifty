@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCLink")
struct OIDCLinkTests {
    /// Logged-in user clicks „Mit SSO verknüpfen“ and comes back from the provider.
    private func linkThroughAccountPage(_ app: Application, _ fake: FakeOIDCProvider, headers: HTTPHeaders) async throws -> OIDCFlowResult {
        let posted = try await browserPost(app, "/account/oidc/link", form: [:], headers: headers)
        #expect(posted.status == .seeOther)
        #expect(posted.location == "/auth/oidc/start")
        return try await oidcFlow(app, fake, headers: posted.headers)
    }

    @Test func linkFromAccountPage() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            let headers = try await login(app, "anna")
            let account = try await browserGet(app, "/account", headers: headers)
            #expect(account.body.contains("Mit SSO verknüpfen"))
            let result = try await linkThroughAccountPage(app, fake, headers: headers)
            #expect(result.location == "/account?sso=linked")
            let reloaded = try #require(try await User.find(user.id, on: app.db))
            #expect(reloaded.oidcSubject == "sub-1")
            #expect(reloaded.oidcIssuer == OIDCTestKeys.issuer)
            let page = try await browserGet(app, "/account?sso=linked", headers: result.headers)
            #expect(page.body.contains("Mit SSO verknüpft."))
            #expect(!page.body.contains("Mit SSO verknüpfen"))
        }
    }

    @Test func linkRequiresSameOrigin() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            try await createUser(app, "anna")
            let headers = try await login(app, "anna").adding(["Origin": "https://evil.example"])
            let posted = try await browserPost(app, "/account/oidc/link", form: [:], headers: headers)
            #expect(posted.status == .forbidden)
        }
    }

    @Test func linkIntentNotFromQuery() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            let headers = try await login(app, "anna")
            let result = try await oidcFlow(app, fake, start: "/auth/oidc/start?intent=link", headers: headers)
            #expect(result.location == "/auth/oidc/new-account")
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == nil)
        }
    }

    @Test func linkReplacesOldIssuer() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user, subject: "old-sub", issuer: "https://old.example")
            let headers = try await login(app, "anna")
            let account = try await browserGet(app, "/account", headers: headers)
            #expect(account.body.contains("Mit SSO verknüpfen"))
            _ = try await linkThroughAccountPage(app, fake, headers: headers)
            let reloaded = try #require(try await User.find(user.id, on: app.db))
            #expect(reloaded.oidcIssuer == OIDCTestKeys.issuer)
            #expect(reloaded.oidcSubject == "sub-1")
        }
    }

    @Test func linkToIdentityOfOtherAccountFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let other = try await createUser(app, "bert")
            try await linkOIDC(app, other)
            let user = try await createUser(app, "anna")
            let headers = try await login(app, "anna")
            let result = try await linkThroughAccountPage(app, fake, headers: headers)
            #expect(result.location == "/account?sso=taken")
            let page = try await browserGet(app, "/account?sso=taken", headers: result.headers)
            #expect(page.body.contains("Dieses SSO-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft."))
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == nil)
            #expect(try await User.find(other.id, on: app.db)?.oidcSubject == "sub-1")
        }
    }

    @Test func concurrentLinkSameIdentityOneWins() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let anna = try await createUser(app, "anna")
            let bert = try await createUser(app, "bert")
            let service = try OIDCLoginService(db: app.db, cipher: app.tokenCipher, oidc: #require(AppConfig.testingOIDC.oidc),
                                               passwordLogin: true, lock: app.oidcIdentityLock)
            async let first: Result<Void, any Error> = { do { try await service.link(anna, to: oidcIdentity()); return .success(()) } catch { return .failure(error) } }()
            async let second: Result<Void, any Error> = { do { try await service.link(bert, to: oidcIdentity()); return .success(()) } catch { return .failure(error) } }()
            let results = await [first, second]
            let failures = results.compactMap { result -> (any Error)? in if case .failure(let e) = result { return e } else { return nil } }
            #expect(failures.count == 1)
            #expect((failures.first as? APIError)?.status == .unprocessableEntity)
            #expect(try await User.query(on: app.db).filter(\.$oidcSubject == "sub-1").count() == 1)
        }
    }

    @Test func linkOnOtherHostRedirectsToCanonicalAccount() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            try await createUser(app, "anna")
            var headers = try await login(app, "anna")
            headers.replaceOrAdd(name: .host, value: "other.lan:8080")
            headers.replaceOrAdd(name: .origin, value: "http://other.lan:8080")
            let posted = try await browserPost(app, "/account/oidc/link", form: [:], headers: headers)
            #expect(posted.status == .seeOther)
            #expect(posted.location == "http://localhost:8080/account?sso=host")
            let page = try await browserGet(app, "/account?sso=host", headers: try await login(app, "anna"))
            #expect(page.body.contains("Verknüpfen geht nur über http://localhost:8080 – dort erneut anmelden und klicken."))
        }
    }

    @Test func linkWithoutOIDCIs404() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            let posted = try await browserPost(app, "/account/oidc/link", form: [:], headers: try await login(app, "anna"))
            #expect(posted.status == .notFound)
            let page = try await browserGet(app, "/account", headers: try await login(app, "anna"))
            #expect(!page.body.contains("verknüpf"))
        }
    }

    @Test func setEmailForAccountWithoutPasswordConflicts() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            let account = try await browserGet(app, "/account", headers: created.headers)
            #expect(account.body.contains("anna@example.org"))
            #expect(account.body.contains("kommt von SSO – dort ändern"))
            #expect(!account.body.contains("action=\"/account/email\""))
            let posted = try await browserPost(app, "/account/email", form: ["email": "x@example.org", "currentPassword": "x"],
                                               headers: created.headers)
            #expect(posted.status == .conflict)
            #expect(posted.body.contains("Die Adresse kommt von SSO – bitte dort ändern."))
        }
    }

    @Test func passwordSectionOnlyWithPassword() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            let account = try await browserGet(app, "/account", headers: created.headers)
            #expect(!account.body.contains("Passwort ändern"))
            #expect(account.body.contains("Mit SSO verknüpft"))

            try await createUser(app, "bert")
            let withPassword = try await browserGet(app, "/account", headers: try await login(app, "bert"))
            #expect(withPassword.body.contains("Passwort ändern"))
        }
    }
}
