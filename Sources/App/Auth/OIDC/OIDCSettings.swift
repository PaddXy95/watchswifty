import Fluent
import Foundation
import Vapor

/// OIDC settings from System → Anmeldung (SSO), stored as one sealed JSON block (contains the client secret).
struct OIDCSettings: Codable, Sendable, Equatable {
    var displayName: String
    var issuer: String
    var clientID: String
    var clientSecret: String
    /// „Adresse von WatchSwifty“ (`https://host[:port]`); the redirect URL is this plus `/auth/oidc/callback`.
    var baseURL: String
    var passwordLogin: Bool = true

    var redirectURL: String { baseURL + "/auth/oidc/callback" }

    var config: OIDCConfig? {
        URL(string: redirectURL).map {
            OIDCConfig(issuer: issuer, clientID: clientID, clientSecret: clientSecret, redirectURL: $0, displayName: displayName)
        }
    }
}

enum OIDCSettingsState: Equatable, Sendable {
    case notConfigured
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    case configured(OIDCSettings)

    var settings: OIDCSettings? {
        if case .configured(let settings) = self { return settings }
        return nil
    }
}

/// The System page's form (and the API's `OIDCSettingsUpdate`). An empty secret keeps the stored one.
struct OIDCSettingsInput: Content {
    var displayName: String?
    var issuer: String
    var clientID: String
    var clientSecret: String?
    var baseURL: String
}

/// Reads and writes the OIDC settings; every change reloads `LoginSettingsStore`, so it applies at once.
struct OIDCSettingsService {
    static let issuerMessage = "Issuer: vollständige Adresse des Providers, z. B. https://auth.example.de/application/o/watchswifty/"
    static let clientIDMessage = "Bitte die Client-ID angeben."
    static let secretMissingMessage = "Bitte das Client-Secret angeben."
    static let secretReentryMessage = "Bitte das Client-Secret neu eingeben – Issuer oder Client-ID wurden geändert."
    static let nameMessage = "Der Anzeigename darf höchstens 40 Zeichen haben."
    static let needsOIDCMessage = "Erst OIDC einrichten."
    static let deleteNeedsPasswordLoginMessage = "Erst den Passwort-Login einschalten."
    static let forcedMessage = "PASSWORD_LOGIN=true ist gesetzt – der Passwort-Login bleibt an, bis die Variable entfernt ist."

    let db: any Database
    let cipher: TokenCipher
    let store: LoginSettingsStore
    let forced: Bool
    let logger: Logger

    func state() async throws -> OIDCSettingsState {
        guard let sealed = try await AppSettings.query(on: db).first()?.oidcConfig, !sealed.isEmpty else { return .notConfigured }
        guard let json = cipher.open(sealed),
              let settings = try? JSONDecoder().decode(OIDCSettings.self, from: Data(json.utf8)) else { return .unreadable }
        return .configured(settings)
    }

    @discardableResult
    func save(_ input: OIDCSettingsInput) async throws -> OIDCSettings {
        let stored = try await state().settings
        var settings = try Self.validated(input, stored: stored)
        settings.passwordLogin = stored?.passwordLogin ?? true
        try await write(settings)
        return settings
    }

    /// Switching off needs a configured provider and the acting admin linked with it (else they lock themselves out).
    func setPasswordLogin(_ enabled: Bool, actingUser: User) async throws {
        guard var settings = try await state().settings else {
            if enabled { return }
            throw APIError.validation(Self.needsOIDCMessage)
        }
        if !enabled {
            guard !forced else { throw APIError.validation(Self.forcedMessage) }
            guard actingUser.isLinked(settings.config) else {
                throw APIError.validation("Verknüpfe zuerst dein eigenes Konto mit \(settings.displayName) (unter Konto) – sonst sperrst du dich aus.")
            }
        }
        settings.passwordLogin = enabled
        try await write(settings)
    }

    func delete() async throws {
        if let settings = try await state().settings, !settings.passwordLogin, !forced {
            throw APIError.validation(Self.deleteNeedsPasswordLoginMessage)
        }
        try await write(nil)
    }

    /// Stores (or removes) the settings without checks – startup seeding for tests and the service's own writes.
    func write(_ settings: OIDCSettings?) async throws {
        let row = try await AppSettings.query(on: db).first() ?? AppSettings()
        row.oidcConfig = try settings.map { try cipher.seal(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) }
        try await row.save(on: db)
        await store.reload(db: db, cipher: cipher, forced: forced, logger: logger)
    }

    private static func validated(_ input: OIDCSettingsInput, stored: OIDCSettings?) throws -> OIDCSettings {
        let name = input.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard name.count <= 40 else { throw APIError.validation(nameMessage) }
        let issuer = input.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: issuer), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.query == nil, url.fragment == nil else {
            throw APIError.validation(issuerMessage)
        }
        let clientID = input.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw APIError.validation(clientIDMessage) }
        guard let baseURL = MailSettingsService.baseURL(input.baseURL) else { throw APIError.validation(MailSettingsService.baseURLMessage) }
        let entered = input.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret: String
        if !entered.isEmpty {
            secret = entered
        } else if let stored {
            guard OIDCConfig.trimmed(stored.issuer) == OIDCConfig.trimmed(issuer), stored.clientID == clientID else {
                throw APIError.validation(secretReentryMessage)
            }
            secret = stored.clientSecret
        } else {
            throw APIError.validation(secretMissingMessage)
        }
        return OIDCSettings(displayName: name.isEmpty ? "SSO" : name, issuer: issuer, clientID: clientID, clientSecret: secret,
                            baseURL: baseURL)
    }
}

struct AddOIDCConfig: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).field("oidc_config", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).deleteField("oidc_config").update()
    }
}

extension Application {
    var oidcSettings: OIDCSettingsService {
        OIDCSettingsService(db: db, cipher: tokenCipher, store: loginSettings, forced: appConfig.passwordLoginForced, logger: logger)
    }
}

extension Request {
    var oidcSettings: OIDCSettingsService {
        OIDCSettingsService(db: db, cipher: application.tokenCipher, store: application.loginSettings,
                            forced: application.appConfig.passwordLoginForced, logger: logger)
    }
}
