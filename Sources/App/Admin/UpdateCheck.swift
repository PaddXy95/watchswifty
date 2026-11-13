import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Newest published release on GitHub.
struct LatestRelease: Sendable, Equatable {
    /// Without the leading „v“, e.g. `0.1.3`.
    let version: String
    let url: String
}

enum ReleaseCheckError: Error, Equatable {
    case notFound, rateLimited, network, invalidResponse
    case http(UInt)

    var message: String {
        switch self {
        case .notFound: "Kein Release gefunden – ist das Repository öffentlich und gibt es schon ein Release?"
        case .rateLimited: "GitHub-Anfragelimit erreicht – bitte später erneut prüfen."
        case .network: "GitHub nicht erreichbar."
        case .invalidResponse: "Unerwartete Antwort von GitHub."
        case .http(let code): "Unerwartete Antwort von GitHub (HTTP \(code))."
        }
    }
}

protocol ReleaseFetcher: Sendable {
    func latestRelease() async throws -> LatestRelease
}

/// Asks the GitHub API for the latest release (no token; 60 requests per hour and IP are plenty).
struct LiveReleaseFetcher: ReleaseFetcher {
    static let url = "https://api.github.com/repos/PaddXy95/watchswifty/releases/latest"

    let client: any Client
    let userAgent: String

    func latestRelease() async throws -> LatestRelease {
        let response: ClientResponse
        do {
            response = try await client.get(URI(string: Self.url), headers: [
                "Accept": "application/vnd.github+json",
                "User-Agent": userAgent,
                "X-GitHub-Api-Version": "2022-11-28",
            ]) { $0.timeout = .seconds(10) }
        } catch {
            throw ReleaseCheckError.network
        }
        switch response.status.code {
        case 200: return try Self.decode(response.body.map { Data($0.readableBytesView) } ?? Data())
        case 404: throw ReleaseCheckError.notFound
        case 403, 429: throw ReleaseCheckError.rateLimited
        default: throw ReleaseCheckError.http(response.status.code)
        }
    }

    static func decode(_ data: Data) throws -> LatestRelease {
        struct Release: Decodable { let tag_name: String; let html_url: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw ReleaseCheckError.invalidResponse }
        return LatestRelease(version: stripV(release.tag_name), url: release.html_url)
    }
}

private func stripV(_ version: String) -> String {
    version.hasPrefix("v") ? String(version.dropFirst()) : version
}

/// Whether `latest` is a newer X.Y.Z release than `current`; nil when either is no release version (e.g. `dev`).
func isNewerVersion(_ latest: String, than current: String) -> Bool? {
    func parts(_ value: String) -> [Int]? {
        let numbers = stripV(value).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
        return numbers.compactMap { $0 }
    }
    guard let new = parts(latest), let old = parts(current) else { return nil }
    return new.lexicographicallyPrecedes(old) == false && new != old
}

/// App-wide settings (one row). Created on first save.
final class AppSettings: Model, @unchecked Sendable {
    static let schema = "app_settings"

    @ID(key: .id) var id: UUID?
    /// Ask GitHub every 12 hours for a new release (off until an admin turns it on).
    @Field(key: "update_check") var updateCheck: Bool
    @OptionalField(key: "checked_at") var checkedAt: Date?
    @OptionalField(key: "latest_version") var latestVersion: String?
    @OptionalField(key: "latest_url") var latestURL: String?
    @OptionalField(key: "check_error") var checkError: String?
    /// Mail settings (`MailSettings` as JSON, sealed with the server key); nil = mail not set up.
    @OptionalField(key: "mail_config") var mailConfig: String?
    /// OIDC settings (`OIDCSettings` as JSON, sealed with the server key); nil = SSO not set up.
    @OptionalField(key: "oidc_config") var oidcConfig: String?
    /// Time of the daily pass (`HH:MM`, server time zone); nil = 07:00.
    @OptionalField(key: "daily_run_time") var dailyRunTime: String?
    /// Start of the last daily pass (a restart within 24 hours waits for the set time).
    @OptionalField(key: "daily_run_at") var dailyRunAt: Date?
    /// KNot webhook address for notifications; nil = webhook off.
    @OptionalField(key: "webhook_url") var webhookURL: String?

    init() {
        self.updateCheck = false
    }
}

struct CreateAppSettings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSettings.schema)
            .id()
            .field("update_check", .bool, .required)
            .field("checked_at", .datetime)
            .field("latest_version", .string)
            .field("latest_url", .string)
            .field("check_error", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).delete()
    }
}

struct AddMailConfig: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).field("mail_config", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).deleteField("mail_config").update()
    }
}

/// Newer release found by the last check (read synchronously when pages are rendered).
final class UpdateStatus: Sendable {
    private let box = NIOLockedValueBox<String?>(nil)

    var newerVersion: String? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

struct UpdateService {
    static let interval: TimeInterval = 12 * 3600

    let db: any Database
    let fetcher: any ReleaseFetcher
    let current: AppVersion
    let status: UpdateStatus

    func settings() async throws -> AppSettings {
        try await AppSettings.query(on: db).first() ?? AppSettings()
    }

    func setEnabled(_ enabled: Bool) async throws {
        let settings = try await settings()
        settings.updateCheck = enabled
        try await settings.save(on: db)
    }

    /// Asks GitHub now; a failure keeps the last known release and stores the error.
    @discardableResult
    func checkNow(now: Date = .now) async throws -> AppSettings {
        let settings = try await settings()
        do {
            let release = try await fetcher.latestRelease()
            settings.latestVersion = release.version
            settings.latestURL = release.url
            settings.checkError = nil
        } catch let error as ReleaseCheckError {
            settings.checkError = error.message
        } catch {
            settings.checkError = ReleaseCheckError.network.message
        }
        settings.checkedAt = now
        try await settings.save(on: db)
        apply(settings)
        return settings
    }

    /// Checks when automatic checks are on and the last one is at least 12 hours old, or predates the installed
    /// version (right after an update the stored result is older than what runs).
    func checkIfDue(now: Date = .now) async throws -> Bool {
        let settings = try await settings()
        guard settings.updateCheck else { return false }
        let outdated = settings.latestVersion.flatMap { isNewerVersion(current.version, than: $0) } == true
        if !outdated, let checked = settings.checkedAt, now.timeIntervalSince(checked) < Self.interval { return false }
        try await checkNow(now: now)
        return true
    }

    func loadStatus() async throws {
        apply(try await settings())
    }

    private func apply(_ settings: AppSettings) {
        status.newerVersion = settings.latestVersion.flatMap { isNewerVersion($0, than: current.version) == true ? $0 : nil }
    }
}

extension Application {
    private struct UpdateStatusKey: StorageKey { typealias Value = UpdateStatus }
    private struct ReleaseFetcherKey: StorageKey { typealias Value = any ReleaseFetcher }

    var updateStatus: UpdateStatus {
        get {
            guard let status = storage[UpdateStatusKey.self] else { fatalError("Update status not configured") }
            return status
        }
        set { storage[UpdateStatusKey.self] = newValue }
    }

    var releaseFetcher: any ReleaseFetcher {
        get {
            guard let fetcher = storage[ReleaseFetcherKey.self] else { fatalError("Release fetcher not configured") }
            return fetcher
        }
        set { storage[ReleaseFetcherKey.self] = newValue }
    }

    var updates: UpdateService {
        UpdateService(db: db, fetcher: releaseFetcher, current: appConfig.appVersion, status: updateStatus)
    }
}

/// Checks hourly whether an automatic update check is due (first 30 s after boot).
struct UpdateCheckLifecycle: LifecycleHandler {
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBootAsync(_ application: Application) async throws {
        let updates = application.updates
        let logger = application.logger
        application.storage[TaskKey.self] = Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                do {
                    if try await updates.checkIfDue(), let newer = updates.status.newerVersion {
                        logger.notice("Neue WatchSwifty-Version verfügbar: v\(newer)")
                    }
                } catch {
                    logger.warning("Update-Prüfung fehlgeschlagen: \(error)")
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }
}
