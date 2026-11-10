@testable import App
import ConsoleKit
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

    // MARK: - Link tokens (Task 8)

    @Test func linkTokenLinksAndSignsIn() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 3600)
            let result = try await oidcFlow(app, fake, start: "/auth/oidc/start?link=\(token)")
            #expect(result.location == "/account?sso=linked")
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == "sub-1")
            #expect(try await OIDCLinkTokenService(db: app.db).check(token) == nil)
            let account = try await browserGet(app, "/account", headers: result.headers)
            #expect(account.body.contains("anna"))
        }
    }

    @Test func linkTokenIsSingleUse() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 3600)
            _ = try await oidcFlow(app, fake, start: "/auth/oidc/start?link=\(token)")
            fake.identity = oidcIdentity("sub-2")
            let again = try await browserGet(app, "/auth/oidc/start?link=\(token)", headers: .sameOrigin)
            #expect(again.status == .badRequest)
            #expect(again.body.contains("Der Verknüpfungslink ist ungültig oder abgelaufen – bitte den Admin um einen neuen bitten."))
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == "sub-1")
        }
    }

    @Test func expiredLinkTokenFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 60,
                                                                         now: Date().addingTimeInterval(-61))
            let result = try await browserGet(app, "/auth/oidc/start?link=\(token)", headers: .sameOrigin)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Der Verknüpfungslink ist ungültig oder abgelaufen"))
        }
    }

    @Test func linkTokenForTakenIdentityFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let other = try await createUser(app, "bert")
            try await linkOIDC(app, other)
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 3600)
            let result = try await oidcFlow(app, fake, start: "/auth/oidc/start?link=\(token)")
            #expect(result.status == .unprocessableEntity)
            #expect(result.body.contains("Dieses SSO-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft."))
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == nil)
        }
    }

    @Test func linkTokenNotUsableAtResetPassword() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 3600)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(page.body.contains("Der Link ist ungültig oder abgelaufen."))
            let post = try await browserPost(app, "/reset-password", form: ["token": token, "password": "newpassword1",
                                                                           "passwordRepeat": "newpassword1"], headers: .sameOrigin)
            #expect(post.body.contains("Der Link ist ungültig oder abgelaufen."))
        }
    }

    @Test func adminSSOLinkMailsWhenPossible() async throws {
        let mail = FakeMailSender()
        try await withTestApp(config: .testingOIDC, mail: mail) { app in
            try await configureMail(app)
            let user = try await createUser(app, "anna")
            user.email = try app.tokenCipher.seal("anna@example.org")
            try await user.save(on: app.db)
            let admin = try await login(app, "admin", password: "adminpass123")
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/sso-link", form: [:], headers: admin)
            #expect(result.status == .ok)
            #expect(result.body.contains("Verknüpfungslink an a•••@example.org gesendet."))
            let sent = try #require(mail.sent.last)
            #expect(sent.to == "anna@example.org")
            #expect(sent.header("Subject") == "WatchSwifty: Konto mit SSO verknüpfen")
            #expect(sent.body.contains("http://localhost:8080/auth/oidc/start?link="))
            #expect(!result.body.contains("/auth/oidc/start?link="))
        }
    }

    @Test func adminSSOLinkShownWithoutMail() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            let admin = try await login(app, "admin", password: "adminpass123")
            let page = try await browserGet(app, "/admin/users", headers: admin)
            #expect(page.body.contains("/admin/users/\(try user.requireID())/sso-link"))
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/sso-link", form: [:], headers: admin)
            #expect(result.status == .ok)
            #expect(result.body.contains("http://localhost:8080/auth/oidc/start?link="))
            #expect(result.body.contains("nur jetzt sichtbar"))
            let again = try await browserGet(app, "/admin/users", headers: admin)
            #expect(!again.body.contains("/auth/oidc/start?link="))
        }
    }

    @Test func adminSSOLinkShownWhenMailFails() async throws {
        let mail = FakeMailSender()
        mail.failure = MailError(message: "550 nope")
        try await withTestApp(config: .testingOIDC, mail: mail) { app in
            try await configureMail(app)
            let user = try await createUser(app, "anna")
            user.email = try app.tokenCipher.seal("anna@example.org")
            try await user.save(on: app.db)
            let admin = try await login(app, "admin", password: "adminpass123")
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/sso-link", form: [:], headers: admin)
            #expect(result.body.contains("/auth/oidc/start?link="))
            #expect(result.body.contains("550 nope"))
        }
    }

    @Test func adminSSOLinkNotForSelfOrLinked() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let adminUser = try #require(try await User.query(on: app.db).filter(\.$username == "admin").first())
            let linked = try await createUser(app, "anna")
            try await linkOIDC(app, linked)
            let admin = try await login(app, "admin", password: "adminpass123")
            let page = try await browserGet(app, "/admin/users", headers: admin)
            #expect(!page.body.contains("/admin/users/\(try adminUser.requireID())/sso-link"))
            #expect(!page.body.contains("/admin/users/\(try linked.requireID())/sso-link"))
            let selfResult = try await browserPost(app, "/admin/users/\(try adminUser.requireID())/sso-link", form: [:], headers: admin)
            #expect(selfResult.status == .unprocessableEntity)
            let linkedResult = try await browserPost(app, "/admin/users/\(try linked.requireID())/sso-link", form: [:], headers: admin)
            #expect(linkedResult.status == .unprocessableEntity)
        }
    }

    @Test func adminSSOLinkWithoutOIDCIs404() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            let admin = try await login(app, "admin", password: "adminpass123")
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/sso-link", form: [:], headers: admin)
            #expect(result.status == .notFound)
        }
    }

    private func runLinkCommand(_ app: Application, _ arguments: [String]) async throws -> ScriptedConsole {
        let console = ScriptedConsole(answers: [])
        var context = CommandContext(console: console, input: CommandInput(arguments: ["App", "link-oidc"] + arguments))
        context.application = app
        try await app.asyncCommands.group().run(using: &context)
        return console
    }

    @Test func linkCommandUnlinksAndPrintsURL() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user, subject: "old")
            let console = try await runLinkCommand(app, ["Anna"])
            #expect(console.printed.contains("Verknüpfungslink für anna (1 Stunde gültig): http://localhost:8080/auth/oidc/start?link="))
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == nil)
            let token = try #require(console.printed.split(separator: "link=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            #expect(try await OIDCLinkTokenService(db: app.db).check(token) != nil)
        }
    }

    @Test func linkCommandWithoutOIDCFails() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            await #expect(throws: CommandFailure.self) { _ = try await runLinkCommand(app, ["anna"]) }
        }
    }

    @Test func linkCommandUnknownUserFails() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            await #expect(throws: CommandFailure("Benutzer „nobody“ gibt es nicht.")) { _ = try await runLinkCommand(app, ["nobody"]) }
        }
    }
}
