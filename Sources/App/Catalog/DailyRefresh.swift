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

/// Token of a user who has the series visible in their library (nil if nobody with a token does).
func refreshToken(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> String? {
    let owners = try await UserTitle.query(on: db).filter(\.$title.$id == titleID).filter(\.$hidden == false).all().map(\.$user.id)
    guard !owners.isEmpty else { return nil }
    return try await User.query(on: db).filter(\.$id ~~ owners).filter(\.$tmdbToken != nil).all()
        .lazy.compactMap { cipher.open($0.tmdbToken) }.first
}

/// Watched titles cached before runtimes were stored (`runtime == nil`), sorted by TMDB id.
func titlesMissingRuntime(on db: any Database) async throws -> [Title] {
    let missing = try await Title.query(on: db).filter(\.$runtime == nil).sort(\.$tmdbID).all()
    guard !missing.isEmpty else { return [] }
    let watched = Set(try await Watch.query(on: db).filter(\.$title.$id ~~ missing.compactMap(\.id)).unique().all(\.$title.$id))
    return missing.filter { $0.id.map(watched.contains) ?? false }
}

/// Token of any user who watched the title (nil if none of them stored one).
func backfillToken(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> String? {
    let watchers = try await Watch.query(on: db).filter(\.$title.$id == titleID).unique().all(\.$user.$id)
    guard !watchers.isEmpty else { return nil }
    return try await User.query(on: db).filter(\.$id ~~ watchers).filter(\.$tmdbToken != nil).sort(\.$username).all()
        .lazy.compactMap { cipher.open($0.tmdbToken) }.first
}

/// Loads runtimes for watched titles that lack them (one refresh each); returns how many were refreshed.
func backfillRuntimes(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger) async -> Int {
    let titles: [Title]
    do { titles = try await titlesMissingRuntime(on: db) } catch {
        logger.warning("Laufzeiten: Abfrage fehlgeschlagen: \(error)")
        return 0
    }
    var refreshed = 0
    for title in titles {
        if Task.isCancelled { break }
        do {
            guard let token = try await backfillToken(for: title.requireID(), on: db, cipher: cipher) else { continue }
            try await CatalogService(db: db, tmdb: provider.make(token)).refresh(title)
            refreshed += 1
        } catch {
            logger.warning("Laufzeit für \(title.name) nicht geladen: \(error)")
        }
    }
    return refreshed
}

/// Refreshes due series one after another: first 60 s after boot, then every 24 h.
struct DailyRefreshLifecycle: LifecycleHandler {
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBootAsync(_ application: Application) async throws {
        let db = application.db
        let provider = application.tmdbProvider
        let worker = application.matchingWorker
        let logger = application.logger
        let cipher = application.tokenCipher
        application.storage[TaskKey.self] = Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                let filled = await backfillRuntimes(db: db, provider: provider, cipher: cipher, logger: logger)
                if filled > 0 { logger.info("Laufzeiten nachgeladen: \(filled) Titel") }
                if let expired = try? await APITokenService(db: db).deleteExpired(), expired > 0 {
                    logger.info("App-API: \(expired) abgelaufene Geräte-Tokens gelöscht")
                }
                if let expired = try? await PasswordTokenService(db: db).deleteExpired(), expired > 0 {
                    logger.info("\(expired) abgelaufene Links zum Passwort-Setzen gelöscht")
                }
                if let expired = try? await OIDCLinkTokenService(db: db).deleteExpired(), expired > 0 {
                    logger.info("\(expired) abgelaufene Verknüpfungslinks gelöscht")
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
                            guard let token = try await refreshToken(for: title.requireID(), on: db, cipher: cipher) else { continue }
                            try await CatalogService(db: db, tmdb: provider.make(token)).refresh(title)
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
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        application.storage[TaskKey.self]?.cancel()
    }
}
