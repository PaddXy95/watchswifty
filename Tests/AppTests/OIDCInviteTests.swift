@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCInvite")
struct OIDCInviteTests {
    /// An invited account without password and its invitation token.
    private func invited(_ app: Application, now: Date = .now) async throws -> (User, String) {
        let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
        try await user.save(on: app.db)
        let token = try await PasswordTokenService(db: app.db).issue(userID: user.requireID(), purpose: .invite, now: now)
        return (user, token)
    }

    @Test func invitePageOffersSSO() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let (_, token) = try await invited(app)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(page.body.contains("Mit SSO verknüpfen"))
            #expect(page.body.contains("/auth/oidc/start?invite=\(token)"))
            #expect(page.body.contains("name=\"password\""))
        }
    }

    @Test func invitePageWithoutOIDCUnchanged() async throws {
        try await withTestApp { app in
            let (_, token) = try await invited(app)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(!page.body.contains("/auth/oidc/start"))
            #expect(page.body.contains("name=\"password\""))
        }
    }

    @Test func resetPageHasNoSSOButton() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            let token = try await PasswordTokenService(db: app.db).issue(userID: user.requireID(), purpose: .reset)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(!page.body.contains("/auth/oidc/start"))
        }
    }

    @Test func inviteViaSSOLinksAndWelcomes() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let (user, token) = try await invited(app)
            let result = try await oidcFlow(app, fake, start: "/auth/oidc/start?invite=\(token)")
            #expect(result.status == .seeOther)
            #expect(result.location == "/account?welcome=1")
            let reloaded = try #require(try await User.find(user.id, on: app.db))
            #expect(reloaded.oidcSubject == "sub-1")
            #expect(reloaded.emailState(app.tokenCipher) == .address("anna@example.org"))
            #expect(try await PasswordToken.query(on: app.db).filter(\.$user.$id == user.requireID()).count() == 0)
            let account = try await browserGet(app, "/account", headers: result.headers)
            #expect(account.body.contains("anna"))
        }
    }

    @Test func expiredInviteViaSSOFails() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let (_, token) = try await invited(app, now: Date().addingTimeInterval(-8 * 86_400))
            let result = try await browserGet(app, "/auth/oidc/start?invite=\(token)", headers: .sameOrigin)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Die Einladung ist abgelaufen – bitte wende dich an deinen Admin."))
        }
    }

    @Test func resetTokenNotAcceptedAsInvite() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await createUser(app, "anna")
            let token = try await PasswordTokenService(db: app.db).issue(userID: user.requireID(), purpose: .reset)
            let result = try await browserGet(app, "/auth/oidc/start?invite=\(token)", headers: .sameOrigin)
            #expect(result.status == .badRequest)
            #expect(result.body.contains("Der Link ist ungültig oder abgelaufen."))
        }
    }

    @Test func inviteForTakenIdentityFails() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let other = try await createUser(app, "bert")
            try await linkOIDC(app, other)
            let (user, token) = try await invited(app)
            let result = try await oidcFlow(app, fake, start: "/auth/oidc/start?invite=\(token)")
            #expect(result.status == .unprocessableEntity)
            #expect(try await User.find(user.id, on: app.db)?.oidcSubject == nil)
            #expect(try await PasswordTokenService(db: app.db).check(token).get().tokenPurpose == .invite)
        }
    }

    @Test func inviteMailMentionsSSO() {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = MailTexts.invite(to: "a@b.de", username: "anna", inviter: "admin", link: "L", expires: expires)
        #expect(!plain.body.contains("SSO"))
        let both = MailTexts.invite(to: "a@b.de", username: "anna", inviter: "admin", link: "L", expires: expires,
                                    ssoName: "SSO", passwordLogin: true)
        #expect(both.body.contains("legst du dein Passwort fest oder verknüpfst dein Konto mit SSO"))
        let ssoOnly = MailTexts.invite(to: "a@b.de", username: "anna", inviter: "admin", link: "L", expires: expires,
                                       ssoName: "SSO", passwordLogin: false)
        #expect(ssoOnly.body.contains("meldest du dich über SSO an"))
        #expect(!ssoOnly.body.contains("Passwort"))
    }

    @Test func adminInviteMailMentionsSSO() async throws {
        let mail = FakeMailSender()
        try await withTestApp(config: .testingOIDC, mail: mail) { app in
            try await configureMail(app)
            let admin = try await login(app, "admin", password: "adminpass123")
            _ = try await browserPost(app, "/admin/users", form: ["username": "anna", "email": "anna@example.org"], headers: admin)
            #expect(mail.sent.last?.body.contains("verknüpfst dein Konto mit SSO") == true)
        }
    }
}
