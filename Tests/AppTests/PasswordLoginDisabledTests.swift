@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("PasswordLoginDisabled")
struct PasswordLoginDisabledTests {
    private var config: AppConfig {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        return config
    }

    /// Signed-in SSO admin (created through the provider, first user → admin).
    private func ssoAdmin(_ app: Application, _ fake: FakeOIDCProvider) async throws -> HTTPHeaders {
        fake.identity = oidcIdentity("admin-sub", username: "chef")
        let page = try await newAccountPage(app, fake)
        let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "chef"], headers: page.headers)
        #expect(try await User.query(on: app.db).filter(\.$username == "chef").first()?.isAdmin == true)
        return created.headers
    }

    @Test func loginPageShowsOnlyOIDC() async throws {
        try await withTestApp(config: config) { app in
            try await configureMail(app)
            let page = try await browserGet(app, "/login", headers: .sameOrigin)
            #expect(page.body.contains("Mit SSO anmelden"))
            #expect(!page.body.contains("name=\"password\""))
            #expect(!page.body.contains("Passwort vergessen?"))
        }
    }

    @Test func passwordLoginReturns404() async throws {
        try await withTestApp(config: config) { app in
            try await createUser(app, "anna")
            let result = try await browserPost(app, "/login", form: ["username": "anna", "password": "password123"], headers: .sameOrigin)
            #expect(result.status == .notFound)
            #expect(!(result.headers.first(name: .cookie) ?? "").contains("watchswifty_session"))
        }
    }

    @Test func forgotReturns404() async throws {
        try await withTestApp(config: config) { app in
            try await configureMail(app)
            #expect(try await browserGet(app, "/forgot-password", headers: .sameOrigin).status == .notFound)
            #expect(try await browserPost(app, "/forgot-password", form: ["username": "anna"], headers: .sameOrigin).status == .notFound)
        }
    }

    @Test func resetLinkInvalidAndPostReturns404() async throws {
        try await withTestApp(config: config) { app in
            let user = try await createUser(app, "anna")
            let token = try await PasswordTokenService(db: app.db).issue(userID: user.requireID(), purpose: .reset)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(page.body.contains("Der Link ist ungültig oder abgelaufen."))
            #expect(!page.body.contains("name=\"password\""))
            let post = try await browserPost(app, "/reset-password", form: ["token": token, "password": "newpassword1",
                                                                           "passwordRepeat": "newpassword1"], headers: .sameOrigin)
            #expect(post.status == .notFound)
        }
    }

    @Test func invitePageOnlySSO() async throws {
        try await withTestApp(config: config) { app in
            let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
            try await user.save(on: app.db)
            let token = try await PasswordTokenService(db: app.db).issue(userID: user.requireID(), purpose: .invite)
            let page = try await browserGet(app, "/reset-password?token=\(token)", headers: .sameOrigin)
            #expect(page.body.contains("Mit SSO verknüpfen"))
            #expect(!page.body.contains("name=\"password\""))
        }
    }

    @Test func accountPasswordReturns404() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: config, oidc: fake) { app in
            let user = try await createUser(app, "anna")
            try await linkOIDC(app, user)
            let flow = try await oidcFlow(app, fake)
            let page = try await browserGet(app, "/account", headers: flow.headers)
            #expect(!page.body.contains("Passwort ändern"))
            let post = try await browserPost(app, "/account/password", form: ["currentPassword": "password123", "newPassword": "newpassword1"],
                                             headers: flow.headers)
            #expect(post.status == .notFound)
        }
    }

    @Test func adminCreateOnlyAsInvitation() async throws {
        let fake = FakeOIDCProvider()
        let mail = FakeMailSender()
        try await withTestApp(config: config, mail: mail, oidc: fake) { app in
            try await configureMail(app)
            let admin = try await ssoAdmin(app, fake)
            let page = try await browserGet(app, "/admin/users", headers: admin)
            #expect(!page.body.contains("Startpasswort"))
            let withPassword = try await browserPost(app, "/admin/users", form: ["username": "bert", "password": "password123"], headers: admin)
            #expect(withPassword.status == .conflict)
            #expect(withPassword.body.contains("Der Passwort-Login ist abgeschaltet – nur Einladungen."))
            let invite = try await browserPost(app, "/admin/users", form: ["username": "bert", "email": "bert@example.org"], headers: admin)
            #expect(invite.status == .ok)
            #expect(mail.sent.last?.to == "bert@example.org")
        }
    }

    @Test func adminSetPasswordReturns404() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: config, oidc: fake) { app in
            let admin = try await ssoAdmin(app, fake)
            let other = try await createUser(app, "bert")
            let page = try await browserGet(app, "/admin/users", headers: admin)
            #expect(!page.body.contains("/admin/users/\(try other.requireID())/password"))
            let result = try await browserPost(app, "/admin/users/\(try other.requireID())/password", form: ["password": "newpassword1"],
                                               headers: admin)
            #expect(result.status == .notFound)
        }
    }

    @Test func servicesThrowPasswordLoginDisabled() async throws {
        try await withTestApp(config: config) { app in
            let user = try await createUser(app, "anna")
            let other = try await createUser(app, "bert")
            let account = AccountService(db: app.db, hasher: app.password.async, tmdbProvider: app.tmdbProvider, cipher: app.tokenCipher,
                                         worker: app.matchingWorker, oidc: config.oidc, passwordLogin: false)
            await #expect(throws: APIError.passwordLoginDisabled()) {
                try await account.changePassword(user: user, current: "password123", new: "newpassword1")
            }
            await #expect(throws: APIError.passwordLoginDisabled()) {
                try await app.userAdmin.resetPassword(id: other.requireID(), password: "newpassword1", actingUserID: user.requireID(),
                                                    confirmation: .recent(true))
            }
            #expect(APIError.passwordLoginDisabled().status == .conflict)
            #expect(APIError.passwordLoginDisabled().code == "passwordLoginDisabled")
        }
    }
}
