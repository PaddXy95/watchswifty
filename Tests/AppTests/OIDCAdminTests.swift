@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCAdmin")
struct OIDCAdminTests {
    private func ssoOnlyUser(_ app: Application, _ name: String, subject: String = "sub-1",
                             issuer: String = OIDCTestKeys.issuer) async throws -> User {
        let user = User(username: name, passwordHash: User.noPasswordHash, isAdmin: false)
        try await user.save(on: app.db)
        try await linkOIDC(app, user, subject: subject, issuer: issuer)
        return user
    }

    @Test func linkedAccountWithoutPasswordIsNoInvitation() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let user = try await ssoOnlyUser(app, "anna")
            let row = try await app.userAdmin.row(for: user)
            #expect(row.invite == .none)
            #expect(row.ssoLinked)
            let page = try await browserGet(app, "/admin/users", headers: try await login(app, "admin", password: "adminpass123"))
            #expect(!page.body.contains("Einladung abgelaufen"))
            #expect(!page.body.contains("/admin/users/\(try user.requireID())/invite"))
            #expect(page.body.contains("<span class=\"badge\">SSO</span>"))
        }
    }

    @Test func resendInviteForLinkedAccountFails() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            try await configureMail(app)
            let user = try await ssoOnlyUser(app, "anna")
            user.email = try app.tokenCipher.seal("anna@example.org")
            try await user.save(on: app.db)
            let admin = try await login(app, "admin", password: "adminpass123")
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/invite", form: [:], headers: admin)
            #expect(result.status == .unprocessableEntity)
            #expect(result.body.contains("Das Konto ist mit SSO verknüpft – keine Einladung nötig."))
        }
    }

    @Test func statusBoxCountsCurrentIssuerOnly() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            _ = try await ssoOnlyUser(app, "anna")
            _ = try await ssoOnlyUser(app, "bert", subject: "sub-2", issuer: "https://old.example")
            let readiness = try await OIDCLoginService.readiness(db: app.db, oidc: try #require(AppConfig.testingOIDC.oidc))
            #expect(readiness == OIDCReadiness(linked: 1, total: 3, adminLinked: false))
            let page = try await browserGet(app, "/admin/users", headers: try await login(app, "admin", password: "adminpass123"))
            #expect(page.body.contains("1 von 3 Konten mit SSO verknüpft"))
            #expect(page.body.contains("Admin verknüpft: nein"))
            #expect(page.body.contains("Erst wenn alle verknüpft sind (mindestens ein Admin), PASSWORD_LOGIN=false setzen."))
        }
    }

    @Test func noStatusBoxWithoutOIDC() async throws {
        try await withTestApp { app in
            let page = try await browserGet(app, "/admin/users", headers: try await login(app, "admin", password: "adminpass123"))
            #expect(!page.body.contains("verknüpft"))
        }
    }

    @Test func oidcDisabledTreatsLinkedAsInvitation() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            let user = try await ssoOnlyUser(app, "anna")
            user.email = try app.tokenCipher.seal("anna@example.org")
            try await user.save(on: app.db)
            let row = try await app.userAdmin.row(for: user)
            #expect(row.invite == .expired)
            #expect(!row.ssoLinked)
            let admin = try await login(app, "admin", password: "adminpass123")
            let result = try await browserPost(app, "/admin/users/\(try user.requireID())/invite", form: [:], headers: admin)
            #expect(result.status == .ok)
            #expect(mail.sent.last?.to == "anna@example.org")
        }
    }

    @Test func startupWarningTexts() throws {
        var config = AppConfig.testingOIDC
        #expect(startupWarnings(config: config, readiness: OIDCReadiness(linked: 0, total: 0, adminLinked: false))
            == ["Kein Benutzer vorhanden – der erste Login über SSO wird Admin."])
        config.passwordLogin = false
        #expect(startupWarnings(config: config, readiness: OIDCReadiness(linked: 1, total: 3, adminLinked: false)) == [
            "Kein Admin ist mit SSO verknüpft – mit `link-oidc <admin>` einen Verknüpfungslink erzeugen.",
            "2 Konten sind noch nicht mit SSO verknüpft (Verknüpfungslink auf der Benutzer-Seite).",
        ])
        #expect(startupWarnings(config: config, readiness: OIDCReadiness(linked: 3, total: 3, adminLinked: true)).isEmpty)
        config.passwordLogin = true
        #expect(startupWarnings(config: config, readiness: OIDCReadiness(linked: 1, total: 3, adminLinked: false)).isEmpty)
    }

    @Test func adminEnvIgnoredWithoutPasswordLogin() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config) { app in
            let count = try await User.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test func firstSSOLoginBecomesAdminWithoutPasswordLogin() async throws {
        let fake = FakeOIDCProvider()
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config, oidc: fake) { app in
            let page = try await newAccountPage(app, fake)
            _ = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "anna"], headers: page.headers)
            #expect(try await User.query(on: app.db).filter(\.$username == "anna").first()?.isAdmin == true)
        }
    }
}
