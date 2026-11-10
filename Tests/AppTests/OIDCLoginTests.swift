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
            #expect(start.location == "http://localhost:8080/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1&oidc_c=1")
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

    @Test func proxyWithoutHostDoesNotLoop() async throws {
        var config = AppConfig.testingOIDC
        config.oidc?.redirectURL = URL(string: "https://nas.lan:8443/auth/oidc/callback")!
        try await withTestApp(config: config) { app in
            let first = try await browserGet(app, "/auth/oidc/start", headers: ["Host": "watchswifty:8080"])
            #expect(first.status == .seeOther)
            #expect(first.location == "https://nas.lan:8443/auth/oidc/start?oidc_c=1")
            // The proxy still sends its own Host: continue instead of redirecting again.
            let second = try await browserGet(app, "/auth/oidc/start?oidc_c=1", headers: ["Host": "watchswifty:8080"])
            #expect(second.status == .seeOther)
            #expect(second.location?.hasPrefix("https://id.example.test/authorize") == true)
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

    // MARK: - New accounts (Task 6)

    @Test func unknownIdentityAlwaysConfirms() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let before = try await User.query(on: app.db).count()
            let page = try await newAccountPage(app, fake)
            #expect(page.status == .ok)
            #expect(page.body.contains("Mit SSO ist noch kein WatchSwifty-Konto verknüpft."))
            #expect(page.body.contains("Hast du schon ein Konto?"))
            #expect(page.body.contains("mit Passwort anmelden"))
            #expect(page.body.contains("value=\"anna\""))
            #expect(try await User.query(on: app.db).count() == before)
        }
    }

    @Test func hintWithoutPasswordLoginNamesTheAdmin() async throws {
        let fake = FakeOIDCProvider()
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            #expect(page.body.contains("den Admin um einen Verknüpfungslink bitten"))
            #expect(!page.body.contains("mit Passwort anmelden"))
        }
    }

    @Test func suggestions() {
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: "Anna")) == "anna")
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: nil, email: "p.meier@x.de")) == "p.meier")
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: "ab@idm.example", email: nil, name: nil)) == nil)
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: "patrick@idm.example", email: nil)) == "patrick")
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: "jörg", email: nil)) == "jrg")
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: nil, email: nil, name: "Jörg Müller")) == "jrgmller")
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: String(repeating: "a", count: 40), email: nil))
            == String(repeating: "a", count: 32))
        #expect(OIDCLoginService.suggestUsername(oidcIdentity(username: nil, email: nil, name: nil)) == nil)
    }

    @Test func suggestionFromEmailOnPage() async throws {
        let fake = FakeOIDCProvider()
        fake.identity = oidcIdentity(username: nil, email: "p.meier@x.de")
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            #expect(page.body.contains("value=\"p.meier\""))
        }
    }

    @Test func nonASCIISuggestionRenders() async throws {
        let fake = FakeOIDCProvider()
        fake.identity = oidcIdentity(username: nil, email: nil, name: "Jörg Müller")
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            #expect(page.status == .ok)
            #expect(page.body.contains("value=\"jrgmller\""))
        }
    }

    @Test func takenSuggestionLeavesFieldEmpty() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            try await createUser(app, "anna")
            let page = try await newAccountPage(app, fake)
            #expect(!page.body.contains("value=\"anna\""))
            #expect(page.body.contains("„anna“ ist schon vergeben"))
        }
    }

    @Test func confirmCreatesAccountWithoutPassword() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "Anna"], headers: page.headers)
            #expect(created.status == .seeOther)
            #expect(created.location == "/account?welcome=1")
            let user = try #require(try await User.query(on: app.db).filter(\.$username == "anna").first())
            #expect(!user.hasPassword)
            #expect(!user.isAdmin)
            #expect(user.oidcIssuer == OIDCTestKeys.issuer)
            #expect(user.oidcSubject == "sub-1")
            #expect(user.email?.hasPrefix(TokenCipher.prefix) == true)
            #expect(user.emailState(app.tokenCipher) == .address("anna@example.org"))
            let account = try await browserGet(app, "/account", headers: created.headers)
            #expect(account.status == .ok)
        }
    }

    @Test func confirmKeepsReturnTo() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake, start: "/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3Fx%3D1")
            let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            #expect(created.location == "/api/auth/authorize?x=1")
        }
    }

    @Test func confirmTakenNameFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            try await createUser(app, "anna")
            let page = try await newAccountPage(app, fake)
            let taken = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            #expect(taken.status == .unprocessableEntity)
            #expect(taken.body.contains(AccountValidation.duplicateMessage))
            let invalid = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "a b"], headers: page.headers)
            #expect(invalid.status == .unprocessableEntity)
            #expect(invalid.body.contains(AccountValidation.usernameMessage))
        }
    }

    @Test func doubleSubmitSignsInOnce() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            let before = try await User.query(on: app.db).count()
            let first = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            let second = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            #expect(first.status == .seeOther)
            #expect(second.status == .seeOther)
            #expect(try await User.query(on: app.db).count() == before + 1)
        }
    }

    @Test func confirmWithoutCookieFails() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let result = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: .sameOrigin)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Anmeldung abgelaufen"))
            let page = try await browserGet(app, "/auth/oidc/new-account", headers: .sameOrigin)
            #expect(page.status == .badRequest)
        }
    }

    @Test func cancelClearsCookie() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            #expect(page.body.contains("/auth/oidc/cancel"))
            let cancelled = try await browserGet(app, "/auth/oidc/cancel", headers: page.headers)
            #expect(cancelled.status == .seeOther)
            #expect(cancelled.location == "/login")
            #expect(!(cancelled.headers.first(name: .cookie) ?? "").contains(OIDCFlowCookie.name))
        }
    }

    @Test func pendingIdentityExpires() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            var flow = OIDCFlowCookie(state: "st", nonce: "no", verifier: "ve", startedAt: Date().addingTimeInterval(-700), intent: .login)
            flow.pending = oidcIdentity()
            flow.pendingAt = Date().addingTimeInterval(-601)
            let headers = HTTPHeaders.sameOrigin.settingCookie(OIDCFlowCookie.name, try flow.seal(app.tokenCipher))
            let result = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: headers)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Anmeldung abgelaufen – bitte erneut versuchen."))
        }
    }

    @Test func firstAccountBecomesAdminOnlyOnEmptyDatabase() async throws {
        var config = AppConfig.testingOIDC
        config.adminUsername = nil
        config.adminPassword = nil
        try await withTestApp(config: config) { app in
            let service = try OIDCLoginService(db: app.db, cipher: app.tokenCipher, oidc: #require(config.oidc), passwordLogin: true,
                                               lock: app.oidcIdentityLock)
            let first = try await service.createAccount(oidcIdentity("s1"), username: "anna")
            let second = try await service.createAccount(oidcIdentity("s2"), username: "bert")
            #expect(first.isAdmin)
            #expect(!second.isAdmin)
        }
    }

    @Test func concurrentFirstLoginsCreateOneAdmin() async throws {
        var config = AppConfig.testingOIDC
        config.adminUsername = nil
        config.adminPassword = nil
        try await withTestApp(config: config) { app in
            let service = try OIDCLoginService(db: app.db, cipher: app.tokenCipher, oidc: #require(config.oidc), passwordLogin: true,
                                               lock: app.oidcIdentityLock)
            try await withThrowingTaskGroup(of: User.self) { group in
                for index in 0..<5 {
                    group.addTask { try await service.createAccount(oidcIdentity("s\(index)"), username: "user\(index)") }
                }
                for try await _ in group {}
            }
            #expect(try await User.query(on: app.db).filter(\.$isAdmin == true).count() == 1)
        }
    }

    @Test func accountWithoutPasswordEmailFollowsProvider() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
            try await user.save(on: app.db)
            try await linkOIDC(app, user)
            fake.identity = oidcIdentity(email: " ANNA@Example.org ")
            _ = try await oidcFlow(app, fake)
            #expect(try await User.find(user.id, on: app.db)?.emailState(app.tokenCipher) == .address("ANNA@example.org"))
            fake.identity = oidcIdentity(email: nil)
            _ = try await oidcFlow(app, fake)
            #expect(try await User.find(user.id, on: app.db)?.emailState(app.tokenCipher) == .address("ANNA@example.org"))
            fake.identity = oidcIdentity(email: "not an address")
            _ = try await oidcFlow(app, fake)
            #expect(try await User.find(user.id, on: app.db)?.emailState(app.tokenCipher) == .address("ANNA@example.org"))
        }
    }

    @Test func accountWithPasswordEmailNeverOverwritten() async throws {
        for passwordLogin in [true, false] {
            let fake = FakeOIDCProvider()
            var config = AppConfig.testingOIDC
            config.passwordLogin = passwordLogin
            try await withTestApp(config: config, oidc: fake) { app in
                let user = try await createUser(app, "anna")
                user.email = try app.tokenCipher.seal("manual@example.org")
                try await user.save(on: app.db)
                try await linkOIDC(app, user)
                _ = try await oidcFlow(app, fake)
                #expect(try await User.find(user.id, on: app.db)?.emailState(app.tokenCipher) == .address("manual@example.org"))
            }
        }
    }

    @Test func passwordLoginForAccountWithoutPasswordStillFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            _ = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            let login = try await browserPost(app, "/login", form: ["username": "anna", "password": User.noPasswordHash],
                                              headers: .sameOrigin)
            #expect(login.body.contains(AuthController.failureMessage))
        }
    }
}
