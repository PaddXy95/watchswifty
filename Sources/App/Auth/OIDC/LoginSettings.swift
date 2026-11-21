import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// The login setup in effect: provider (from System → Anmeldung (SSO)) and whether passwords work.
struct LoginSettings: Sendable, Equatable {
    var oidc: OIDCConfig?
    var passwordLogin: Bool
    /// `PASSWORD_LOGIN=true` keeps the password login on whatever the settings say (emergency switch).
    var passwordLoginForced: Bool

    /// No provider, password login on: the state before the settings are loaded.
    static let passwordsOnly = LoginSettings(oidc: nil, passwordLogin: true, passwordLoginForced: false)
}

/// Current `LoginSettings`, readable without awaiting; reloaded at startup and after every settings change.
final class LoginSettingsStore: Sendable {
    private let value = NIOLockedValueBox(LoginSettings.passwordsOnly)

    /// The settings in effect.
    var current: LoginSettings { value.withLockedValue { $0 } }

    /// Reloads the settings from `app_settings`; unreadable settings (changed server key) switch SSO off and the
    /// password login on, with a warning in the log.
    /// - Parameters:
    ///   - db: The database.
    ///   - cipher: Opens the sealed settings.
    ///   - forced: Whether `PASSWORD_LOGIN=true` is set.
    ///   - logger: Receives the warning.
    func reload(db: any Database, cipher: TokenCipher, forced: Bool, logger: Logger) async {
        let service = OIDCSettingsService(db: db, cipher: cipher, store: self, forced: forced, logger: logger)
        var settings = LoginSettings(oidc: nil, passwordLogin: true, passwordLoginForced: forced)
        switch (try? await service.state()) ?? .notConfigured {
        case .configured(let stored):
            settings.oidc = stored.config
            settings.passwordLogin = forced || stored.passwordLogin
        case .unreadable:
            logger.warning("OIDC-Einstellungen nicht lesbar (Server-Schlüssel geändert?) – SSO ist aus, Passwort-Login an.")
        case .notConfigured:
            break
        }
        let result = settings
        value.withLockedValue { $0 = result }
    }
}

/// One provider client per settings state, so discovery and key caches start fresh when the settings change.
final class OIDCProviderStore: Sendable {
    private let factory: @Sendable (OIDCConfig) -> any OIDCProvider
    private let cached = NIOLockedValueBox<(config: OIDCConfig, provider: any OIDCProvider)?>(nil)

    /// Creates the store.
    /// - Parameter factory: Builds a provider client for a config (`LiveOIDCProvider` in production, a fake in tests).
    init(factory: @escaping @Sendable (OIDCConfig) -> any OIDCProvider) {
        self.factory = factory
    }

    /// The cached client when the config is unchanged, otherwise a new one that replaces it.
    /// - Parameter config: The provider config in effect.
    /// - Returns: The provider client.
    func provider(for config: OIDCConfig) -> any OIDCProvider {
        cached.withLockedValue { cached in
            if let cached, cached.config == config { return cached.provider }
            let provider = factory(config)
            cached = (config, provider)
            return provider
        }
    }
}

extension Application {
    /// Storage key for `loginSettings`.
    private struct LoginSettingsKey: StorageKey { typealias Value = LoginSettingsStore }
    /// Storage key for `oidcProviders`.
    private struct OIDCProviderStoreKey: StorageKey { typealias Value = OIDCProviderStore }

    /// The app-wide login settings; traps when `configure` has not set them.
    var loginSettings: LoginSettingsStore {
        get {
            guard let store = storage[LoginSettingsKey.self] else { fatalError("Login settings not configured") }
            return store
        }
        set { storage[LoginSettingsKey.self] = newValue }
    }

    /// The app-wide provider client cache; traps when `configure` has not set it.
    var oidcProviders: OIDCProviderStore {
        get {
            guard let store = storage[OIDCProviderStoreKey.self] else { fatalError("OIDC providers not configured") }
            return store
        }
        set { storage[OIDCProviderStoreKey.self] = newValue }
    }
}
