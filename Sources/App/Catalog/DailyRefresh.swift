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

/// Refreshes due series one after another: first 60 s after boot, then every 24 h.
struct DailyRefreshLifecycle: LifecycleHandler {
    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBootAsync(_ application: Application) async throws {
        let db = application.db
        let tmdb = application.tmdb
        let logger = application.logger
        application.storage[TaskKey.self] = Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                do {
                    let due = try await seriesDueForRefresh(on: db)
                    let catalog = CatalogService(db: db, tmdb: tmdb)
                    for title in due {
                        if Task.isCancelled { break }
                        do { try await catalog.refresh(title) } catch {
                            logger.warning("TMDB-Abgleich für \(title.name) fehlgeschlagen: \(error)")
                        }
                    }
                    logger.info("TMDB-Abgleich: \(due.count) Serien aktualisiert")
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
