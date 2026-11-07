import Fluent
import Foundation
import Vapor

/// Series that need a TMDB refresh so new episodes appear: in at least one user's library and
/// visible there, and not finished at TMDB.
func seriesDueForRefresh(on db: any Database) async throws -> [Title] {
    let visible = try await UserTitle.query(on: db).filter(\.$hidden == false).all().map(\.$title.id)
    guard !visible.isEmpty else { return [] }
    return try await Title.query(on: db).filter(\.$id ~~ Array(Set(visible)))
        .filter(\.$kind == TitleKind.tv.rawValue).all()
        .filter { !["Ended", "Canceled"].contains($0.tmdbStatus ?? "") }
}

/// Token of a user who has the series visible in their library (nil if nobody with a token does).
func refreshToken(for titleID: UUID, on db: any Database) async throws -> String? {
    let owners = try await UserTitle.query(on: db).filter(\.$title.$id == titleID).filter(\.$hidden == false).all().map(\.$user.id)
    guard !owners.isEmpty else { return nil }
    return try await User.query(on: db).filter(\.$id ~~ owners).filter(\.$tmdbToken != nil).all()
        .compactMap(\.tmdbToken).first { !$0.isEmpty }
}

/// Refreshes due series one after another: first 60 s after boot, then every 24 h.
struct DailyRefreshLifecycle: LifecycleHandler {
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBootAsync(_ application: Application) async throws {
        let db = application.db
        let provider = application.tmdbProvider
        let worker = application.matchingWorker
        let logger = application.logger
        application.storage[TaskKey.self] = Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                do {
                    let due = try await seriesDueForRefresh(on: db)
                    var requeued = 0
                    for title in due {
                        if Task.isCancelled { break }
                        do {
                            guard let token = try await refreshToken(for: title.requireID(), on: db) else { continue }
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
