import Foundation

enum ConfigError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing(let name): "Fehlende Umgebungsvariable: \(name)"
        case .invalid(let message): message
        }
    }
}

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

    static func fromEnvironment(_ env: [String: String]) throws -> AppConfig {
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
        return config
    }

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
