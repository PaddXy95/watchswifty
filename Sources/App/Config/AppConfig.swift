import Foundation

/// Startup configuration error; its German description is printed before the process exits.
enum ConfigError: Error, Equatable, CustomStringConvertible {
    /// A required environment variable is not set (associated value: its name).
    case missing(String)
    /// A setting is unusable (associated value: the German message shown as is).
    case invalid(String)

    /// The German message for the console.
    var description: String {
        switch self {
        case .missing(let name): "Fehlende Umgebungsvariable: \(name)"
        case .invalid(let message): message
        }
    }
}

/// Server configuration, read from the environment at startup (`entrypoint.swift`) or built for tests (`testing`).
struct AppConfig: Sendable {
    var tmdbLanguage: String
    var databasePath: String
    var host: String
    var port: Int
    var adminUsername: String?
    var adminPassword: String?
    var loginFailureDelay: Duration
    var backgroundJobsEnabled: Bool
    var bcryptCost: Int = 12
    /// „Today“ for the app (process time zone); pinned in tests so dates never expire.
    var today: @Sendable () -> String = { CalendarDay.today() }
    /// Extra origins accepted by the CSRF check (behind reverse proxies), e.g. `https://nas.lan:8443`.
    var publicOrigins: [String] = []
    /// Server key for the stored TMDB tokens (`TOKEN_KEY`, Base64) or a file holding it (`TOKEN_KEY_FILE`).
    var tokenKey: String? = nil
    var tokenKeyFile: String? = nil
    /// Version of this build (compared with the latest GitHub release).
    var appVersion: AppVersion = .current
    /// Longest wait for one mail sent while the request waits (invitation, test mail).
    var mailDeadline: Duration = .seconds(30)
    /// Test seed only (never read from the environment): written as the OIDC settings at startup.
    var oidc: OIDCConfig? = nil
    /// Test seed only: the password-login switch stored with `oidc`.
    var passwordLogin: Bool = true
    /// `PASSWORD_LOGIN=true`: emergency switch that keeps the password login on (settings live under System).
    var passwordLoginForced: Bool = false
    /// Variables that are set but no longer read (logged at startup).
    var environmentHints: [String] = []

    /// Builds the configuration from environment variables, with defaults for everything optional.
    ///
    /// Of `PASSWORD_LOGIN` only the value `true` has an effect; other values and the retired `OIDC_*` variables are
    /// collected in `environmentHints` (SSO is set up under System).
    /// - Parameter env: The process environment.
    /// - Returns: The configuration.
    /// - Throws: Declared for `ConfigError`; no current variable makes it fail.
    static func fromEnvironment(_ env: [String: String]) throws -> AppConfig {
        /// The trimmed value of a variable; nil when unset or blank.
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        let publicOrigins = (value("PUBLIC_ORIGIN") ?? "").split(separator: ",")
            .map { OriginCheckMiddleware.normalizeOrigin(String($0)) }.filter { !$0.isEmpty }
        var config = AppConfig(
            tmdbLanguage: value("TMDB_LANGUAGE") ?? "de-DE",
            databasePath: value("DATABASE_PATH") ?? "/data/watchswifty.sqlite",
            host: value("HOST") ?? "0.0.0.0",
            port: value("PORT").flatMap(Int.init) ?? 8080,
            adminUsername: value("ADMIN_USERNAME"),
            adminPassword: value("ADMIN_PASSWORD"),
            loginFailureDelay: .seconds(1),
            backgroundJobsEnabled: true,
            publicOrigins: publicOrigins,
            tokenKey: value("TOKEN_KEY"),
            tokenKeyFile: value("TOKEN_KEY_FILE")
        )
        config.passwordLoginForced = value("PASSWORD_LOGIN")?.lowercased() == "true"
        if let raw = value("PASSWORD_LOGIN"), !config.passwordLoginForced {
            config.environmentHints.append(
                "PASSWORD_LOGIN=\(raw) wird ignoriert – nur PASSWORD_LOGIN=true wirkt (Notschalter); den Passwort-Login unter Admin → System abschalten.")
        }
        for name in ["OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET", "OIDC_CLIENT_SECRET_FILE", "OIDC_REDIRECT_URL", "OIDC_NAME"]
        where value(name) != nil {
            config.environmentHints.append("\(name) wird ignoriert – SSO wird unter Admin → System → Anmeldung über OIDC (SSO) eingerichtet.")
        }
        return config
    }

    /// Configuration for tests: in-memory SQLite, bcrypt cost 4, no login delay, background jobs off and today pinned
    /// to `2026-11-07`.
    static var testing: AppConfig {
        var config = AppConfig(
            tmdbLanguage: "de-DE",
            databasePath: ":memory:",
            host: "127.0.0.1",
            port: 8080,
            adminUsername: "admin",
            adminPassword: "adminpass123",
            loginFailureDelay: .zero,
            backgroundJobsEnabled: false,
            bcryptCost: 4
        )
        config.today = { "2026-11-07" }
        return config
    }

    /// `testing` with an OIDC provider whose canonical address is the test host (`http://localhost:8080`).
    static var testingOIDC: AppConfig {
        var config = testing
        config.oidc = OIDCConfig(issuer: "https://id.example.test", clientID: "watchswifty", clientSecret: "secret",
                                 redirectURL: URL(string: "http://localhost:8080/auth/oidc/callback")!, displayName: "SSO")
        return config
    }
}
