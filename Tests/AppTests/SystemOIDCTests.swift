@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("SystemOIDC")
struct SystemOIDCTests {
    private let form = ["displayName": "Authentik", "issuer": "https://id.example.test", "clientID": "watchswifty",
                        "clientSecret": "very-secret-value", "baseURL": "http://localhost:8080"]

    private func admin(_ app: Application) async throws -> HTTPHeaders {
        try await login(app, "admin", password: "adminpass123")
    }

    @Test func sectionShowsNotConfigured() async throws {
        try await withTestApp { app in
            let page = try await browserGet(app, "/admin/system", headers: try await admin(app))
            #expect(page.body.contains("Anmeldung über OIDC (SSO)"))
            #expect(page.body.contains("Nicht eingerichtet."))
            #expect(page.body.contains("action=\"/admin/system/oidc\""))
        }
    }

    @Test func saveActivatesImmediately() async throws {
        try await withTestApp { app in
            let saved = try await browserPost(app, "/admin/system/oidc", form: form, headers: try await admin(app))
            #expect(saved.status == .ok)
            #expect(saved.body.contains("Anmelde-Einstellungen gespeichert."))
            #expect(saved.body.contains("Verbindung in Ordnung: Issuer https://id.example.test, 1 Schlüssel."))
            #expect(saved.body.contains("http://localhost:8080/auth/oidc/callback"))
            #expect(!saved.body.contains("very-secret-value"))
            #expect(saved.body.contains("gespeichert – leer lassen zum Behalten"))
            let loginPage = try await browserGet(app, "/login", headers: .sameOrigin)
            #expect(loginPage.body.contains("Mit Authentik anmelden"))
        }
    }

    @Test func saveWithFailingCheckStillSaves() async throws {
        let fake = FakeOIDCProvider()
        fake.startError = .unreachable
        try await withTestApp(oidc: fake) { app in
            let saved = try await browserPost(app, "/admin/system/oidc", form: form, headers: try await admin(app))
            #expect(saved.status == .ok)
            #expect(saved.body.contains("Gespeichert, aber die Prüfung schlug fehl: Authentik ist nicht erreichbar."))
            #expect(app.loginSettings.current.oidc != nil)
        }
    }

    @Test func validationErrorKeepsForm() async throws {
        try await withTestApp { app in
            var bad = form
            bad["issuer"] = "not a url"
            let result = try await browserPost(app, "/admin/system/oidc", form: bad, headers: try await admin(app))
            #expect(result.status == .unprocessableEntity)
            #expect(result.body.contains(OIDCSettingsService.issuerMessage))
            #expect(result.body.contains("value=\"Authentik\""))
            #expect(app.loginSettings.current.oidc == nil)
        }
    }

    @Test func testButton() async throws {
        try await withTestApp { app in
            let headers = try await admin(app)
            let missing = try await browserPost(app, "/admin/system/oidc/test", form: [:], headers: headers)
            #expect(missing.status == .unprocessableEntity)
            #expect(missing.body.contains("Erst OIDC einrichten."))
            _ = try await browserPost(app, "/admin/system/oidc", form: form, headers: headers)
            let tested = try await browserPost(app, "/admin/system/oidc/test", form: [:], headers: headers)
            #expect(tested.status == .ok)
            #expect(tested.body.contains("Verbindung in Ordnung: Issuer https://id.example.test, 1 Schlüssel."))
        }
    }

    @Test func deleteAndGuard() async throws {
        try await withTestApp { app in
            let headers = try await admin(app)
            _ = try await browserPost(app, "/admin/system/oidc", form: form, headers: headers)
            let deleted = try await browserPost(app, "/admin/system/oidc/delete", form: [:], headers: headers)
            #expect(deleted.body.contains("Anmelde-Einstellungen gelöscht."))
            #expect(app.loginSettings.current.oidc == nil)
        }
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        let fake = FakeOIDCProvider()
        try await withTestApp(config: config, oidc: fake) { app in
            fake.identity = oidcIdentity("chef-sub", username: "chef")
            let page = try await newAccountPage(app, fake)
            let created = try await browserPost(app, "/auth/oidc/new-account", form: ["username": "chef"], headers: page.headers)
            let blocked = try await browserPost(app, "/admin/system/oidc/delete", form: [:], headers: created.headers)
            #expect(blocked.status == .unprocessableEntity)
            #expect(blocked.body.contains("Erst den Passwort-Login einschalten."))
        }
    }

    @Test func passwordLoginToggle() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(oidc: fake) { app in
            let headers = try await admin(app)
            let noOIDC = try await browserPost(app, "/admin/system/password-login", form: ["enabled": "false"], headers: headers)
            #expect(noOIDC.status == .unprocessableEntity)
            #expect(noOIDC.body.contains("Erst OIDC einrichten."))
            _ = try await browserPost(app, "/admin/system/oidc", form: form, headers: headers)
            let notLinked = try await browserPost(app, "/admin/system/password-login", form: ["enabled": "false"], headers: headers)
            #expect(notLinked.status == .unprocessableEntity)
            #expect(notLinked.body.contains("Verknüpfe zuerst dein eigenes Konto mit Authentik"))
            let adminUser = try #require(try await User.query(on: app.db).filter(\.$username == "admin").first())
            try await linkOIDC(app, adminUser)
            let off = try await browserPost(app, "/admin/system/password-login", form: ["enabled": "false"], headers: headers)
            #expect(off.status == .ok)
            #expect(off.body.contains("Passwort-Login abgeschaltet."))
            #expect(!app.loginSettings.current.passwordLogin)
            let loginPage = try await browserGet(app, "/login", headers: .sameOrigin)
            #expect(!loginPage.body.contains("name=\"password\""))
            let on = try await browserPost(app, "/admin/system/password-login", form: ["enabled": "true"], headers: headers)
            #expect(on.body.contains("Passwort-Login eingeschaltet."))
            #expect(app.loginSettings.current.passwordLogin)
        }
    }

    @Test func forcedShownAndLocked() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false   // stored: off – the emergency switch overrides it
        config.passwordLoginForced = true
        try await withTestApp(config: config) { app in
            let headers = try await admin(app)
            let page = try await browserGet(app, "/admin/system", headers: headers)
            #expect(page.body.contains("Per PASSWORD_LOGIN=true erzwungen"))
            #expect(page.body.contains("Gespeichert: aus – gilt wieder, sobald die Variable entfernt ist."))
            #expect(!page.body.contains("Passwort-Login abschalten"))
            #expect(page.body.contains("Passwort-Login dauerhaft einschalten"))
            let on = try await browserPost(app, "/admin/system/password-login", form: ["enabled": "true"], headers: headers)
            #expect(on.body.contains("Passwort-Login eingeschaltet."))
            #expect(try await app.oidcSettings.state().settings?.passwordLogin == true)
            #expect(!on.body.contains("Gespeichert: aus"))
        }
    }

    @Test func nonAdminForbidden() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            let headers = try await login(app, "anna")
            for path in ["/admin/system/oidc", "/admin/system/oidc/test", "/admin/system/oidc/delete", "/admin/system/password-login"] {
                let result = try await browserPost(app, path, form: form, headers: headers)
                #expect(result.status == .forbidden)
            }
        }
    }
}
