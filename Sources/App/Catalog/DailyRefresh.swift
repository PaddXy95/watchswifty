import Fluent
import Foundation
import Vapor

/// Series that need a TMDB refresh so new episodes appear: in at least one user's library and
/// visible there, and not finished at TMDB.
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
func refreshTokens(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> [String] {
    let owners = try await UserTitle.query(on: db).filter(\.$title.$id == titleID)
        .group(.or) { $0.filter(\.$hidden == false).filter(\.$followed == true) }.all().map(\.$user.id)
    guard !owners.isEmpty else { return [] }
    return try await User.query(on: db).filter(\.$id ~~ owners).filter(\.$tmdbToken != nil).sort(\.$username).all()
        .compactMap { cipher.open($0.tmdbToken) }
}

/// Runs `body` with each token in turn until TMDB accepts one: a user's revoked token must not block a title they
/// share with others (security audit F13). Other errors (TMDB down …) end the attempt; false when there is no token.
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
func titlesMissingDetails(on db: any Database) async throws -> [Title] {
    let missing = try await Title.query(on: db).group(.or) { $0.filter(\.$runtime == nil).filter(\.$genres == nil) }
        .sort(\.$tmdbID).all()
    guard !missing.isEmpty else { return [] }
    let watched = Set(try await Watch.query(on: db).filter(\.$title.$id ~~ missing.compactMap(\.id)).unique().all(\.$title.$id))
    return missing.filter { $0.id.map(watched.contains) ?? false }
}

/// Tokens of the users who watched the title, ordered by username.
func backfillTokens(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> [String] {
    let watchers = try await Watch.query(on: db).filter(\.$title.$id == titleID).unique().all(\.$user.$id)
    guard !watchers.isEmpty else { return [] }
    return try await User.query(on: db).filter(\.$id ~~ watchers).filter(\.$tmdbToken != nil).sort(\.$username).all()
        .compactMap { cipher.open($0.tmdbToken) }
}

/// Loads runtimes and genres for watched titles that lack them (one refresh each); returns how many were refreshed.
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

/// One daily pass: runtimes, expired tokens, TMDB cache upkeep, refresh of due series, then notifications; recorded
/// as the last run only when it completed.
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
/// the last pass is more than 24 hours old; a new time under System wakes the loop so it applies immediately.
struct DailyRefreshLifecycle: LifecycleHandler {
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

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

    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }
}
