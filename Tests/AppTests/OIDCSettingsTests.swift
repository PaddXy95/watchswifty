@testable import App
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCSettings")
struct OIDCSettingsTests {
    private func input(issuer: String = "https://id.example.test", clientID: String = "watchswifty", secret: String? = "s3cret",
                       baseURL: String = "https://watch.example.lan", name: String? = nil) -> OIDCSettingsInput {
        OIDCSettingsInput(displayName: name, issuer: issuer, clientID: clientID, clientSecret: secret, baseURL: baseURL)
    }

    private func expectValidation(_ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected „\(message)“")
        } catch let error as APIError {
            #expect(error.message == message)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func notConfiguredByDefault() async throws {
        try await withTestApp { app in
            let state = try await app.oidcSettings.state()
            #expect(state == .notConfigured)
            #expect(app.loginSettings.current.oidc == nil)
            #expect(app.loginSettings.current.passwordLogin)
        }
    }

    @Test func testConfigIsSeeded() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let settings = try #require(try await app.oidcSettings.state().settings)
            #expect(settings.issuer == "https://id.example.test")
            #expect(settings.baseURL == "http://localhost:8080")
            #expect(app.loginSettings.current.oidc?.redirectURL.absoluteString == "http://localhost:8080/auth/oidc/callback")
        }
    }

    @Test func saveValidates() async throws {
        try await withTestApp { app in
            let service = app.oidcSettings
            await expectValidation(OIDCSettingsService.issuerMessage) { _ = try await service.save(input(issuer: "id.example.test")) }
            await expectValidation(OIDCSettingsService.clientIDMessage) { _ = try await service.save(input(clientID: " ")) }
            await expectValidation(OIDCSettingsService.secretMissingMessage) { _ = try await service.save(input(secret: "")) }
            await expectValidation(MailSettingsService.baseURLMessage) { _ = try await service.save(input(baseURL: "https://w.lan/app")) }
            await expectValidation(OIDCSettingsService.nameMessage) {
                _ = try await service.save(input(name: String(repeating: "x", count: 41)))
            }
            let state = try await service.state()
            #expect(state == .notConfigured)
        }
    }

    @Test func saveStoresSealedAndActivatesAtOnce() async throws {
        try await withTestApp { app in
            let saved = try await app.oidcSettings.save(input(baseURL: "https://watch.example.lan/", name: " "))
            #expect(saved.displayName == "SSO")
            let row = try #require(try await AppSettings.query(on: app.db).first())
            #expect(row.oidcConfig?.hasPrefix(TokenCipher.prefix) == true)
            #expect(row.oidcConfig?.contains("s3cret") == false)
            let current = try #require(app.loginSettings.current.oidc)
            #expect(current.issuer == "https://id.example.test")
            #expect(current.clientSecret == "s3cret")
            #expect(current.redirectURL.absoluteString == "https://watch.example.lan/auth/oidc/callback")
            #expect(app.loginSettings.current.passwordLogin)
        }
    }

    @Test func emptySecretKeepsStored() async throws {
        try await withTestApp { app in
            _ = try await app.oidcSettings.save(input())
            let again = try await app.oidcSettings.save(input(secret: "", name: "Authentik"))
            #expect(again.clientSecret == "s3cret")
            #expect(app.loginSettings.current.oidc?.displayName == "Authentik")
        }
    }

    @Test func changedIssuerOrClientNeedsSecret() async throws {
        try await withTestApp { app in
            _ = try await app.oidcSettings.save(input())
            await expectValidation(OIDCSettingsService.secretReentryMessage) {
                _ = try await app.oidcSettings.save(input(issuer: "https://evil.example", secret: nil))
            }
            await expectValidation(OIDCSettingsService.secretReentryMessage) {
                _ = try await app.oidcSettings.save(input(clientID: "other", secret: nil))
            }
            _ = try await app.oidcSettings.save(input(issuer: "https://new.example", secret: "new-secret"))
            #expect(app.loginSettings.current.oidc?.clientSecret == "new-secret")
        }
    }

    @Test func unreadableSettingsTurnOIDCOff() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let row = try #require(try await AppSettings.query(on: app.db).first())
            row.oidcConfig = try TokenCipher(key: SymmetricKey(size: .bits256)).seal("{}")
            try await row.save(on: app.db)
            await app.loginSettings.reload(db: app.db, cipher: app.tokenCipher, forced: false, logger: app.logger)
            let state = try await app.oidcSettings.state()
            #expect(state == .unreadable)
            #expect(app.loginSettings.current.oidc == nil)
            #expect(app.loginSettings.current.passwordLogin)
        }
    }

    @Test func passwordLoginSwitchGuards() async throws {
        try await withTestApp { app in
            let admin = try #require(try await User.query(on: app.db).filter(\.$username == "admin").first())
            await expectValidation(OIDCSettingsService.needsOIDCMessage) {
                try await app.oidcSettings.setPasswordLogin(false, actingUser: admin)
            }
            _ = try await app.oidcSettings.save(input())
            await expectValidation("Verknüpfe zuerst dein eigenes Konto mit SSO (unter Konto) – sonst sperrst du dich aus.") {
                try await app.oidcSettings.setPasswordLogin(false, actingUser: admin)
            }
            try await linkOIDC(app, admin)
            try await app.oidcSettings.setPasswordLogin(false, actingUser: admin)
            #expect(!app.loginSettings.current.passwordLogin)
            #expect(try await app.oidcSettings.state().settings?.passwordLogin == false)
            try await app.oidcSettings.setPasswordLogin(true, actingUser: admin)
            #expect(app.loginSettings.current.passwordLogin)
        }
    }

    @Test func deleteBlockedWhilePasswordLoginOff() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config) { app in
            await expectValidation(OIDCSettingsService.deleteNeedsPasswordLoginMessage) { try await app.oidcSettings.delete() }
            let admin = User(username: "chef", passwordHash: User.noPasswordHash, isAdmin: true)
            try await admin.save(on: app.db)
            try await app.oidcSettings.setPasswordLogin(true, actingUser: admin)
            try await app.oidcSettings.delete()
            let state = try await app.oidcSettings.state()
            #expect(state == .notConfigured)
            #expect(app.loginSettings.current.oidc == nil)
        }
    }

    @Test func forcedPasswordLogin() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        config.passwordLoginForced = true
        try await withTestApp(config: config) { app in
            #expect(app.loginSettings.current.passwordLogin)
            #expect(app.loginSettings.current.passwordLoginForced)
            let admin = User(username: "chef", passwordHash: User.noPasswordHash, isAdmin: true)
            try await admin.save(on: app.db)
            try await linkOIDC(app, admin)
            await expectValidation(OIDCSettingsService.forcedMessage) {
                try await app.oidcSettings.setPasswordLogin(false, actingUser: admin)
            }
        }
    }

    @Test func savingSwitchesProviderAtRuntime() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let first = app.oidcProviders.provider(for: try #require(app.loginSettings.current.oidc))
            let same = app.oidcProviders.provider(for: try #require(app.loginSettings.current.oidc))
            #expect(first as AnyObject === same as AnyObject)
            _ = try await app.oidcSettings.save(input(issuer: "https://new.example", secret: "x"))
            #expect(app.loginSettings.current.oidc?.issuer == "https://new.example")
        }
    }

    @Test func canonicalOriginAllowedAtRuntime() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            _ = try await app.oidcSettings.save(input(baseURL: "https://watch.example.lan"))
            var headers = try await login(app, "anna")
            headers.replaceOrAdd(name: .origin, value: "https://watch.example.lan")
            headers.replaceOrAdd(name: .host, value: "internal:8080")
            let result = try await browserPost(app, "/account/oidc/link", form: ["currentPassword": "password123"], headers: headers)
            #expect(result.status == .seeOther)
            #expect(result.location == "/auth/oidc/start")
        }
    }
}
