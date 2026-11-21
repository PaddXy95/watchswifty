import Fluent
import Foundation
import Vapor

/// Series that need a TMDB refresh so new episodes appear: in at least one user's library and
/// visible there, and not finished at TMDB.
/// - Parameter db: The database to read from.
/// - Returns: Due series; titles TMDB reports as "Ended" or "Canceled" are left out.
/// - Throws: Database errors.
func seriesDueForRefresh(on db: any Database) async throws -> [Title] {
    // Visible in someone's library, or followed (also when hidden) so new episodes are noticed.
    let visible = try await UserTitle.query(on: db).group(.or) { group in
        group.filter(\.$hidden == false).filter(\.$followed == true)
    }.all().map(\.$title.id)
    guard !visible.isEmpty else { return [] }
    return try await Title.query(on: db).filter(\.$id ~~ Array(Set(visible)))
        .filter(\.$kind == TitleKind.tv.rawValue).all()
        .filter { !["Ended", "Canceled"].contains($0.tmdbStatus ?? "") }
}

/// Tokens of the users who have the series visible in their library or follow it (the same users that make it due
/// in `seriesDueForRefresh`), ordered by username.
/// - Parameters:
///   - titleID: The series' ID.
///   - db: The database to read from.
///   - cipher: Decrypts the stored tokens.
/// - Returns: The decrypted tokens; users without a token (or with one that fails to decrypt) are skipped.
/// - Throws: Database errors.
func refreshTokens(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> [String] {
    let owners = try await UserTitle.query(on: db).filter(\.$title.$id == titleID)
        .group(.or) { $0.filter(\.$hidden == false).filter(\.$followed == true) }.all().map(\.$user.id)
    guard !owners.isEmpty else { return [] }
    return try await User.query(on: db).filter(\.$id ~~ owners).filter(\.$tmdbToken != nil).sort(\.$username).all()
        .compactMap { cipher.open($0.tmdbToken) }
}

/// Runs `body` with each token in turn until TMDB accepts one: a user's revoked token must not block a title they
/// share with others (security audit F13). Other errors (TMDB down …) end the attempt; false when there is no token.
/// - Parameters:
///   - tokens: The candidate tokens, tried in order.
///   - body: The TMDB work to run with one token.
/// - Returns: `true` once `body` succeeded with a token; `false` when `tokens` is empty.
/// - Throws: Any error of `body` other than `TMDBError.unauthorized`; `TMDBError.unauthorized` only when the last
///   token is rejected too.
func withAcceptedToken(_ tokens: [String], _ body: (String) async throws -> Void) async throws -> Bool {
    for (index, token) in tokens.enumerated() {
        do {
            try await body(token)
            return true
        } catch TMDBError.unauthorized where index < tokens.count - 1 {
            continue
        }
    }
    return false
}

/// Watched titles cached before runtimes or genres were stored (`runtime` or `genres` nil), sorted by TMDB id.
/// - Parameter db: The database to read from.
/// - Returns: Titles lacking runtime or genres that at least one user has watched.
/// - Throws: Database errors.
func titlesMissingDetails(on db: any Database) async throws -> [Title] {
    let missing = try await Title.query(on: db).group(.or) { $0.filter(\.$runtime == nil).filter(\.$genres == nil) }
        .sort(\.$tmdbID).all()
    guard !missing.isEmpty else { return [] }
    let watched = Set(try await Watch.query(on: db).filter(\.$title.$id ~~ missing.compactMap(\.id)).unique().all(\.$title.$id))
    return missing.filter { $0.id.map(watched.contains) ?? false }
}

/// Tokens of the users who watched the title, ordered by username.
/// - Parameters:
///   - titleID: The title's ID.
///   - db: The database to read from.
///   - cipher: Decrypts the stored tokens.
/// - Returns: The decrypted tokens of the watchers who have one.
/// - Throws: Database errors.
func backfillTokens(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> [String] {
    let watchers = try await Watch.query(on: db).filter(\.$title.$id == titleID).unique().all(\.$user.$id)
    guard !watchers.isEmpty else { return [] }
    return try await User.query(on: db).filter(\.$id ~~ watchers).filter(\.$tmdbToken != nil).sort(\.$username).all()
        .compactMap { cipher.open($0.tmdbToken) }
}

/// Loads runtimes and genres for watched titles that lack them (one refresh each); returns how many were refreshed.
///
/// Each title is refreshed with a watcher's token (``withAcceptedToken(_:_:)``); failures are logged and skipped, and
/// the loop stops when the task is cancelled.
/// - Parameters:
///   - db: The database holding the catalog.
///   - provider: Creates TMDB clients for user tokens.
///   - cipher: Decrypts the stored tokens.
///   - logger: Receives warnings.
/// - Returns: The number of titles refreshed.
func backfillDetails(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger) async -> Int {
    let titles: [Title]
    do { titles = try await titlesMissingDetails(on: db) } catch {
        logger.warning("Laufzeiten/Genres: Abfrage fehlgeschlagen: \(error)")
        return 0
    }
    var refreshed = 0
    for title in titles {
        if Task.isCancelled { break }
        do {
            let tokens = try await backfillTokens(for: title.requireID(), on: db, cipher: cipher)
            if try await withAcceptedToken(tokens, { try await CatalogService(db: db, tmdb: provider.make($0)).refresh(title) }) {
                refreshed += 1
            }
        } catch {
            logger.warning("Laufzeit/Genres für \(title.name) nicht geladen: \(error)")
        }
    }
    return refreshed
}

/// One daily pass: runtimes, expired tokens, TMDB cache upkeep, refresh of due series, availability of „Später ansehen“
/// titles, then notifications; recorded
/// as the last run only when it completed.
///
/// Also deletes expired App API device tokens, password links, OIDC link tokens and idle web sessions, and requeues
/// unmatched Netflix rows of refreshed series. A failing step does not stop the pass; failures are logged, except for
/// the token and session cleanups, which are skipped silently.
/// - Parameters:
///   - application: The application providing database, TMDB provider, workers and settings.
///   - now: The pass's start time, stored as the last run and used as the reference for idle sessions and
///     availability.
func runDailyPass(_ application: Application, now: Date = .now) async {
    let db = application.db
    let provider = application.tmdbProvider
    let worker = application.matchingWorker
    let logger = application.logger
    let cipher = application.tokenCipher
    let filled = await backfillDetails(db: db, provider: provider, cipher: cipher, logger: logger)
    if filled > 0 { logger.info("Laufzeiten/Genres nachgeladen: \(filled) Titel") }
    if let expired = try? await APITokenService(db: db).deleteExpired(), expired > 0 {
        logger.info("App-API: \(expired) abgelaufene Geräte-Tokens gelöscht")
    }
    if let expired = try? await PasswordTokenService(db: db).deleteExpired(), expired > 0 {
        logger.info("\(expired) abgelaufene Links zum Passwort-Setzen gelöscht")
    }
    if let expired = try? await OIDCLinkTokenService(db: db).deleteExpired(), expired > 0 {
        logger.info("\(expired) abgelaufene Verknüpfungslinks gelöscht")
    }
    if let idle = try? await WebSession.deleteIdle(on: db, now: now), idle > 0 {
        logger.info("\(idle) unbenutzte Web-Sitzungen beendet")
    }
    let maintenance = await maintainCatalog(db: db, provider: provider, cipher: cipher, logger: logger)
    if !maintenance.isEmpty {
        logger.info("TMDB-Cache-Pflege: \(maintenance.refreshed) aktualisiert, \(maintenance.deleted) gelöscht, \(maintenance.cleared) geleert, \(maintenance.candidatesCleared) Vorschlagslisten verworfen")
    }
    do {
        let due = try await seriesDueForRefresh(on: db)
        var requeued = 0
        for title in due {
            if Task.isCancelled { break }
            do {
                let tokens = try await refreshTokens(for: title.requireID(), on: db, cipher: cipher)
                guard try await withAcceptedToken(tokens, { try await CatalogService(db: db, tmdb: provider.make($0)).refresh(title) })
                else { continue }
                requeued += try await requeueUnmatchedRows(titleID: title.requireID(), on: db)
            } catch {
                logger.warning("TMDB-Abgleich für \(title.name) fehlgeschlagen: \(error)")
            }
        }
        logger.info("TMDB-Abgleich: \(due.count) Serien geprüft, \(requeued) Netflix-Zeilen erneut zur Zuordnung")
        if requeued > 0 { await worker.kick() }
    } catch {
        logger.error("TMDB-Abgleich fehlgeschlagen: \(error)")
    }
    let available = await refreshWatchLaterAvailability(db: db, provider: provider, cipher: cipher, logger: logger, now: now)
    if available != AvailabilityPassResult() {
        logger.info("Verfügbarkeit: \(available.refreshed) Titel abgefragt, \(available.failed) fehlgeschlagen, \(available.expired) veraltet gelöscht")
    }
    let notified = await runNotifications(db: db, notifications: application.notifications, today: application.appConfig.today(),
                                          logger: logger)
    if notified.sent > 0 || notified.failed > 0 {
        logger.info("Benachrichtigungen: \(notified.sent) verschickt, \(notified.failed) fehlgeschlagen")
    }
    // Only a complete pass counts (its start time): one cut short by a shutdown is repeated after the restart.
    guard !Task.isCancelled else { return }
    do { try await application.notificationSettings.markRun(at: now) } catch {
        logger.warning("Täglicher Durchgang: Zeitpunkt nicht gespeichert: \(error)")
    }
}

/// Runs the daily pass at the admin's time (server time zone). After a start it runs at once (after 60 s) only when
/// the set time has passed since the last complete pass (``DailySchedule/runsAtBoot(lastRun:now:time:timeZone:)``);
/// a new time under System wakes the loop so it applies immediately.
struct DailyRefreshLifecycle: LifecycleHandler {
    /// Storage key for the scheduling task, so shutdown can cancel it.
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    /// Starts the scheduling loop after boot: a catch-up pass after 60 s if due, then one pass per day at the configured
    /// time, re-planned whenever `DailyRunTrigger` signals a changed time.
    /// - Parameter application: The booted application.
    func didBootAsync(_ application: Application) async throws {
        let trigger = application.dailyRunTrigger
        let settings = application.notificationSettings
        let logger = application.logger
        application.storage[TaskKey.self] = Task {
            let stored = try? await settings.settings()
            if DailySchedule.runsAtBoot(lastRun: stored?.lastRunAt, now: .now, time: stored?.dailyRunTime ?? DailySchedule.defaultTime,
                                        timeZone: .current) {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await runDailyPass(application)
            }
            while !Task.isCancelled {
                let time = (try? await settings.settings().dailyRunTime) ?? DailySchedule.defaultTime
                let next = DailySchedule.nextRun(after: .now, time: time, timeZone: .current)
                logger.info("Nächster täglicher Durchgang: \(formatDateTime(next)) Uhr")
                if await trigger.sleep(until: next) { continue }
                if Task.isCancelled { break }
                await runDailyPass(application)
            }
        }
    }

    /// Cancels the scheduling loop (a running pass stops early and is not recorded as the last run).
    /// - Parameter application: The application shutting down.
    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }
}
