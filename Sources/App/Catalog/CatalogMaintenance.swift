import Fluent
import Foundation
import Vapor

/// TMDB's API terms forbid caching TMDB data for more than 6 months. Every title is re-fetched after 60 days with the
/// token of a user who uses it; unused titles are dropped.
enum CatalogMaintenance {
    static let maxAge: TimeInterval = 60 * 86_400
    /// TMDB's limit: without a refresh, TMDB texts are cleared after this.
    static let hardLimit: TimeInterval = 180 * 86_400
    /// Keeps the daily TMDB load small; the rest follows on the next days.
    static let refreshesPerPass = 200
}

struct MaintenanceResult: Equatable, Sendable {
    var refreshed = 0
    var deleted = 0
    var cleared = 0
    var candidatesCleared = 0

    var isEmpty: Bool { self == MaintenanceResult() }
}

/// Users of each title: watches, library entries (rating/hidden/follow/comment), season comments, Netflix mappings and
/// film list entries.
func titleUsers(on db: any Database) async throws -> [UUID: Set<UUID>] {
    var users: [UUID: Set<UUID>] = [:]
    for watch in try await Watch.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[watch.$title.id, default: []].insert(watch.$user.id)
    }
    for entry in try await UserTitle.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[entry.$title.id, default: []].insert(entry.$user.id)
    }
    for note in try await SeasonNote.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[note.$title.id, default: []].insert(note.$user.id)
    }
    for mapping in try await NetflixMapping.query(on: db).filter(\.$title.$id != nil).all() {
        if let titleID = mapping.$title.id { users[titleID, default: []].insert(mapping.$user.id) }
    }
    let listed = try await FilmListEntry.query(on: db).filter(\.$tmdbID != nil).all()
    if !listed.isEmpty {
        let movies = try await Title.query(on: db).filter(\.$kind == TitleKind.movie.rawValue)
            .filter(\.$tmdbID ~~ Array(Set(listed.compactMap(\.tmdbID)))).all()
        let movieByTMDB = Dictionary(movies.compactMap { movie in movie.id.map { (movie.tmdbID, $0) } }, uniquingKeysWith: { a, _ in a })
        for entry in listed {
            if let titleID = entry.tmdbID.flatMap({ movieByTMDB[$0] }) { users[titleID, default: []].insert(entry.$user.id) }
        }
    }
    return users
}

/// One maintenance pass (part of the daily TMDB pass).
func maintainCatalog(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger, now: Date = .now,
                     refreshLimit: Int = CatalogMaintenance.refreshesPerPass) async -> MaintenanceResult {
    var result = MaintenanceResult()
    do {
        let cutoff = now.addingTimeInterval(-CatalogMaintenance.maxAge)
        let hardCutoff = now.addingTimeInterval(-CatalogMaintenance.hardLimit)
        let stale = try await Title.query(on: db)
            .group(.or) { $0.filter(\.$refreshedAt == nil).filter(\.$refreshedAt < cutoff) }
            .sort(\.$refreshedAt, .ascending).all()
        if !stale.isEmpty {
            let users = try await titleUsers(on: db)
            let tokens = Dictionary(try await User.query(on: db).filter(\.$tmdbToken != nil).all().compactMap { user in
                user.id.flatMap { id in cipher.open(user.tmdbToken).map { (id, $0) } }
            }, uniquingKeysWith: { a, _ in a })

            for title in stale {
                guard let titleID = title.id else { continue }
                let owners = users[titleID] ?? []
                if owners.isEmpty {
                    try await Episode.query(on: db).filter(\.$title.$id == titleID).delete()
                    try await title.delete(on: db)
                    result.deleted += 1
                    continue
                }
                // Only the token of someone who uses the title, never a stranger's.
                if let token = owners.sorted(by: { $0.uuidString < $1.uuidString }).lazy.compactMap({ tokens[$0] }).first {
                    guard result.refreshed < refreshLimit else { continue }
                    do {
                        try await CatalogService(db: db, tmdb: provider.make(token)).refresh(title, now: now)
                        result.refreshed += 1
                    } catch {
                        logger.warning("TMDB-Cache: \(title.name) nicht aktualisiert: \(error)")
                    }
                    continue
                }
                if (title.refreshedAt ?? .distantPast) < hardCutoff, try await clearTMDBTexts(title, on: db) {
                    result.cleared += 1
                }
            }
        }

        for mapping in try await NetflixMapping.query(on: db).filter(\.$candidates != nil).all()
        where (mapping.candidatesAt ?? .distantPast) < cutoff {
            mapping.candidates = nil
            mapping.candidatesAt = nil
            try await mapping.save(on: db)
            result.candidatesCleared += 1
        }
        for entry in try await FilmListEntry.query(on: db).filter(\.$candidates != nil).all()
        where (entry.createdAt ?? .distantPast) < cutoff {
            entry.candidates = nil
            try await entry.save(on: db)
            result.candidatesCleared += 1
        }
    } catch {
        logger.error("TMDB-Cache-Pflege fehlgeschlagen: \(error)")
    }
    return result
}

/// Clears texts, runtimes and genres (name, episodes and air dates stay for the user's history); true if anything was set.
private func clearTMDBTexts(_ title: Title, on db: any Database) async throws -> Bool {
    let titleID = try title.requireID()
    let episodes = try await Episode.query(on: db).filter(\.$title.$id == titleID)
        .group(.or) { $0.filter(\.$overview != nil).filter(\.$runtime != nil) }.all()
    guard title.overview != nil || title.imdbID != nil || title.runtime != nil || title.genres != nil || !episodes.isEmpty else {
        return false
    }
    title.overview = nil
    title.imdbID = nil
    title.runtime = nil
    title.genres = nil
    try await title.save(on: db)
    for episode in episodes {
        episode.overview = nil
        episode.runtime = nil
        try await episode.save(on: db)
    }
    return true
}
