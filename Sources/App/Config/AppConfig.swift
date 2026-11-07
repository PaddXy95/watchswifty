import Foundation

enum ConfigError: Error, Equatable, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let name): "Fehlende Umgebungsvariable: \(name)"
        }
    }
}

struct AppConfig: Sendable {
    var tmdbToken: String
    var tmdbLanguage: String
    var databasePath: String
    var host: String
    var port: Int
    var adminUsername: String?
    var adminPassword: String?
    var loginFailureDelay: Duration
    var backgroundJobsEnabled: Bool

    static func fromEnvironment(_ env: [String: String]) throws -> AppConfig {
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        guard let token = value("TMDB_TOKEN") else { throw ConfigError.missing("TMDB_TOKEN") }
        return AppConfig(
            tmdbToken: token,
            tmdbLanguage: value("TMDB_LANGUAGE") ?? "de-DE",
            databasePath: value("DATABASE_PATH") ?? "/data/watchswifty.sqlite",
            host: value("HOST") ?? "0.0.0.0",
            port: value("PORT").flatMap(Int.init) ?? 8080,
            adminUsername: value("ADMIN_USERNAME"),
            adminPassword: value("ADMIN_PASSWORD"),
            loginFailureDelay: .seconds(1),
            backgroundJobsEnabled: true
        )
    }

    static var testing: AppConfig {
        AppConfig(
            tmdbToken: "test",
            tmdbLanguage: "de-DE",
            databasePath: ":memory:",
            host: "127.0.0.1",
            port: 8080,
            adminUsername: "admin",
            adminPassword: "adminpass123",
            loginFailureDelay: .zero,
            backgroundJobsEnabled: false
        )
    }
}
