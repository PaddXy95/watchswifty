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

    static func fromEnvironment(_ env: [String: String]) throws -> AppConfig {
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        return AppConfig(
            tmdbLanguage: value("TMDB_LANGUAGE") ?? "de-DE",
            databasePath: value("DATABASE_PATH") ?? "/data/watchswifty.sqlite",
            host: value("HOST") ?? "0.0.0.0",
            port: value("PORT").flatMap(Int.init) ?? 8080,
            adminUsername: value("ADMIN_USERNAME"),
            adminPassword: value("ADMIN_PASSWORD"),
            loginFailureDelay: .seconds(1),
            backgroundJobsEnabled: true,
            publicOrigins: (value("PUBLIC_ORIGIN") ?? "").split(separator: ",").map { OriginCheckMiddleware.normalizeOrigin(String($0)) }
                .filter { !$0.isEmpty },
            tokenKey: value("TOKEN_KEY"),
            tokenKeyFile: value("TOKEN_KEY_FILE")
        )
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
}
