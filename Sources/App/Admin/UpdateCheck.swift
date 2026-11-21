import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Newest published release on GitHub.
struct LatestRelease: Sendable, Equatable {
    /// Without the leading „v“, e.g. `0.1.3`.
    let version: String
    /// Address of the release page on GitHub.
    let url: String
}

/// Why asking GitHub for the latest release failed.
enum ReleaseCheckError: Error, Equatable {
    /// `notFound`: no release (or no public repository); `rateLimited`: GitHub answered 403/429; `network`: GitHub was
    /// not reachable; `invalidResponse`: the body could not be decoded.
    case notFound, rateLimited, network, invalidResponse
    /// Any other unexpected HTTP status code.
    case http(UInt)

    /// German error text shown on the system page and stored in `AppSettings.checkError`.
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

/// Source of the newest published release; faked in tests.
protocol ReleaseFetcher: Sendable {
    /// Fetches the newest published release.
    /// - Returns: The release's version (without leading „v“) and page URL.
    /// - Throws: A `ReleaseCheckError` (or any other error) when the release cannot be determined.
    func latestRelease() async throws -> LatestRelease
}

/// Asks the GitHub API for the latest release (no token; 60 requests per hour and IP are plenty).
struct LiveReleaseFetcher: ReleaseFetcher {
    /// GitHub API endpoint for the latest release of the WatchSwifty repository.
    static let url = "https://api.github.com/repos/PaddXy95/watchswifty/releases/latest"

    /// HTTP client used for the request.
    let client: any Client
    /// `User-Agent` header value (required by the GitHub API).
    let userAgent: String

    /// Fetches the latest release from the GitHub API (10 second timeout).
    /// - Returns: The release's version (without leading „v“) and page URL.
    /// - Throws: `ReleaseCheckError.network` when the request fails, `.notFound` on 404, `.rateLimited` on 403/429,
    ///   `.http` on other status codes, `.invalidResponse` when the body cannot be decoded.
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

    /// Decodes a GitHub release response body.
    /// - Parameter data: JSON body of `GET /repos/…/releases/latest`.
    /// - Returns: The release with the „v“ prefix stripped from its tag name.
    /// - Throws: `ReleaseCheckError.invalidResponse` when the body is no valid JSON or `tag_name`/`html_url` is missing.
    static func decode(_ data: Data) throws -> LatestRelease {
        /// The two fields of a GitHub release response the check needs.
        struct Release: Decodable { let tag_name: String; let html_url: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw ReleaseCheckError.invalidResponse }
        return LatestRelease(version: stripV(release.tag_name), url: release.html_url)
    }
}

/// Removes a leading „v“ from a version tag.
/// - Parameter version: A version such as `v0.1.3` or `0.1.3`.
/// - Returns: The version without the „v“ prefix.
private func stripV(_ version: String) -> String {
    version.hasPrefix("v") ? String(version.dropFirst()) : version
}

/// Whether `latest` is a newer X.Y.Z release than `current`; nil when either is no release version (e.g. `dev`).
/// - Parameters:
///   - latest: The candidate version, with or without leading „v“.
///   - current: The version to compare against, with or without leading „v“.
/// - Returns: `true` if `latest` is newer, `false` if not, nil if either is not an X.Y.Z version.
func isNewerVersion(_ latest: String, than current: String) -> Bool? {
    /// Splits a version into its three numeric components.
    /// - Parameter value: A version, with or without leading „v“.
    /// - Returns: `[X, Y, Z]`, or nil unless the value is exactly three dot-separated integers.
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

    /// Primary key of the single settings row.
    @ID(key: .id) var id: UUID?
    /// Ask GitHub every 12 hours for a new release (off until an admin turns it on).
    @Field(key: "update_check") var updateCheck: Bool
    /// When the last update check (successful or not) ran.
    @OptionalField(key: "checked_at") var checkedAt: Date?
    /// Version of the newest release found so far (without „v“).
    @OptionalField(key: "latest_version") var latestVersion: String?
    /// GitHub page of the newest release found so far.
    @OptionalField(key: "latest_url") var latestURL: String?
    /// German error message of the last failed check; nil after a successful one.
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

    /// Creates the default settings (update check off).
    init() {
        self.updateCheck = false
    }
}

/// Migration that creates the `app_settings` table with the update check columns.
struct CreateAppSettings: AsyncMigration {
    /// Creates the `app_settings` table.
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

    /// Drops the `app_settings` table.
    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).delete()
    }
}

/// Migration that adds the sealed `mail_config` column to `app_settings`.
struct AddMailConfig: AsyncMigration {
    /// Adds the `mail_config` column.
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).field("mail_config", .string).update()
    }

    /// Removes the `mail_config` column.
    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).deleteField("mail_config").update()
    }
}

/// Newer release found by the last check (read synchronously when pages are rendered).
final class UpdateStatus: Sendable {
    /// Lock-protected storage for `newerVersion`.
    private let box = NIOLockedValueBox<String?>(nil)

    /// Version of a release newer than the running one, or nil when up to date or unknown.
    var newerVersion: String? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

/// Reads and changes the update check setting and asks GitHub for new releases.
///
/// The result is stored in `AppSettings` and mirrored into the in-memory `UpdateStatus` so pages can show a hint
/// without a database query.
struct UpdateService {
    /// Minimum time between two automatic checks (12 hours).
    static let interval: TimeInterval = 12 * 3600

    let db: any Database
    let fetcher: any ReleaseFetcher
    let current: AppVersion
    let status: UpdateStatus

    /// Loads the settings row, or a new unsaved default one when none exists yet.
    /// - Returns: The app-wide settings.
    /// - Throws: Database errors.
    func settings() async throws -> AppSettings {
        try await AppSettings.query(on: db).first() ?? AppSettings()
    }

    /// Turns the automatic update check on or off.
    /// - Parameter enabled: Whether to check GitHub every 12 hours.
    /// - Throws: Database errors.
    func setEnabled(_ enabled: Bool) async throws {
        let settings = try await settings()
        settings.updateCheck = enabled
        try await settings.save(on: db)
    }

    /// Asks GitHub now; a failure keeps the last known release and stores the error.
    ///
    /// Also updates `UpdateStatus`.
    /// - Parameter now: The check time to store.
    /// - Returns: The saved settings with the check result.
    /// - Throws: Database errors (fetch errors are stored, not thrown).
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
    /// - Parameter now: The current time.
    /// - Returns: Whether a check ran.
    /// - Throws: Database errors.
    func checkIfDue(now: Date = .now) async throws -> Bool {
        let settings = try await settings()
        guard settings.updateCheck else { return false }
        let outdated = settings.latestVersion.flatMap { isNewerVersion(current.version, than: $0) } == true
        if !outdated, let checked = settings.checkedAt, now.timeIntervalSince(checked) < Self.interval { return false }
        try await checkNow(now: now)
        return true
    }

    /// Fills `UpdateStatus` from the stored result of the last check (called at startup).
    /// - Throws: Database errors.
    func loadStatus() async throws {
        apply(try await settings())
    }

    /// Sets `UpdateStatus.newerVersion` to the stored latest version if it is newer than the running one.
    /// - Parameter settings: The settings holding the last check result.
    private func apply(_ settings: AppSettings) {
        status.newerVersion = settings.latestVersion.flatMap { isNewerVersion($0, than: current.version) == true ? $0 : nil }
    }
}

extension Application {
    /// Storage key for the shared `UpdateStatus`.
    private struct UpdateStatusKey: StorageKey { typealias Value = UpdateStatus }
    /// Storage key for the configured `ReleaseFetcher`.
    private struct ReleaseFetcherKey: StorageKey { typealias Value = any ReleaseFetcher }

    /// The app-wide update status; crashes if `configure` did not set it.
    var updateStatus: UpdateStatus {
        get {
            guard let status = storage[UpdateStatusKey.self] else { fatalError("Update status not configured") }
            return status
        }
        set { storage[UpdateStatusKey.self] = newValue }
    }

    /// The release fetcher (live or fake); crashes if `configure` did not set it.
    var releaseFetcher: any ReleaseFetcher {
        get {
            guard let fetcher = storage[ReleaseFetcherKey.self] else { fatalError("Release fetcher not configured") }
            return fetcher
        }
        set { storage[ReleaseFetcherKey.self] = newValue }
    }

    /// An update service over the app's database, release fetcher and running version.
    var updates: UpdateService {
        UpdateService(db: db, fetcher: releaseFetcher, current: appConfig.appVersion, status: updateStatus)
    }
}

/// Checks hourly whether an automatic update check is due (first 30 s after boot).
struct UpdateCheckLifecycle: LifecycleHandler {
    /// Storage key for the background check task, so shutdown can cancel it.
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    /// Starts the background task that calls `UpdateService.checkIfDue` every hour and logs a newer version.
    /// - Parameter application: The booted application.
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

    /// Cancels the background check task.
    /// - Parameter application: The application shutting down.
    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }
}
