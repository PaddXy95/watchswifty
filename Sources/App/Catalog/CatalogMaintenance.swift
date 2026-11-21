import Fluent
import Foundation
import Vapor

/// TMDB's API terms forbid caching TMDB data for more than 6 months. Every title is re-fetched after 60 days with the
/// token of a user who uses it; unused titles are dropped.
enum CatalogMaintenance {
    /// Age after which a cached title is re-fetched from TMDB (60 days).
    static let maxAge: TimeInterval = 60 * 86_400
    /// TMDB's limit: without a refresh, TMDB texts are cleared after this.
    static let hardLimit: TimeInterval = 180 * 86_400
    /// Keeps the daily TMDB load small; the rest follows on the next days.
    static let refreshesPerPass = 200
}

/// Counters of one ``maintainCatalog(db:provider:cipher:logger:now:refreshLimit:)`` pass, logged by the daily pass.
struct MaintenanceResult: Equatable, Sendable {
    /// Stale titles re-fetched from TMDB with a user's token.
    var refreshed = 0
    /// Stale titles no user uses any more, deleted together with their episodes.
    var deleted = 0
    /// Titles whose TMDB texts were cleared because they went 180 days without a refresh.
    var cleared = 0
    /// Netflix mappings and standard import entries whose cached TMDB candidate lists were discarded.
    var candidatesCleared = 0

    /// Whether the pass changed nothing at all.
    var isEmpty: Bool { self == MaintenanceResult() }
}

/// Users of each title: watches, library entries (rating/hidden/follow/comment), season comments, Netflix mappings,
/// matched standard import entries and „Später ansehen“ entries. Availability data and notices deliberately do not count.
///
/// This is the authoritative list of tables that keep a title cached: a new per-user table referencing titles must be
/// added here (and to ``usesTitle(userID:title:on:)``), or ``maintainCatalog(db:provider:cipher:logger:now:refreshLimit:)``
/// deletes its titles. Import entries are resolved to titles by kind and TMDB id.
/// - Parameter db: The database to read from.
/// - Returns: For each title ID, the IDs of the users who use it; titles without users are absent.
/// - Throws: Database errors.
func titleUsers(on db: any Database) async throws -> [UUID: Set<UUID>] {
    var users: [UUID: Set<UUID>] = [:]
    for watch in try await Watch.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[watch.$title.id, default: []].insert(watch.$user.id)
    }
    for entry in try await UserTitle.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[entry.$title.id, default: []].insert(entry.$user.id)
    }
    for entry in try await WatchLaterEntry.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[entry.$title.id, default: []].insert(entry.$user.id)
    }
    for note in try await SeasonNote.query(on: db).field(\.$user.$id).field(\.$title.$id).unique().all() {
        users[note.$title.id, default: []].insert(note.$user.id)
    }
    for mapping in try await NetflixMapping.query(on: db).filter(\.$title.$id != nil).all() {
        if let titleID = mapping.$title.id { users[titleID, default: []].insert(mapping.$user.id) }
    }
    let imported = try await ImportEntry.query(on: db).filter(\.$tmdbID != nil).all()
    for kind in TitleKind.allCases {
        let entries = imported.filter { $0.titleKind == kind }
        guard !entries.isEmpty else { continue }
        var byTMDB: [Int: UUID] = [:]
        for tmdbIDs in Array(Set(entries.compactMap(\.tmdbID))).chunked() {
            for title in try await Title.query(on: db).filter(\.$kind == kind.rawValue).filter(\.$tmdbID ~~ Array(tmdbIDs)).all() {
                if let id = title.id, byTMDB[title.tmdbID] == nil { byTMDB[title.tmdbID] = id }
            }
        }
        for entry in entries {
            if let titleID = entry.tmdbID.flatMap({ byTMDB[$0] }) { users[titleID, default: []].insert(entry.$user.id) }
        }
    }
    return users
}

/// Whether one user uses the title, by the same tables as `titleUsers`: request paths without the user's own TMDB
/// token only serve cached titles the user uses, because which titles are cached reflects other users' tracking
/// (security audit F14).
/// - Parameters:
///   - userID: The user to check.
///   - title: The cached title (must have an ID).
///   - db: The database to read from.
/// - Returns: `true` if any of the user's watches, library entries, „Später ansehen“ entries, season comments, Netflix
///   mappings or standard import entries refers to the title.
/// - Throws: Fluent's error for a title without ID, or database errors.
func usesTitle(userID: UUID, title: Title, on db: any Database) async throws -> Bool {
    let titleID = try title.requireID()
    if try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil { return true }
    if try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil { return true }
    if try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil { return true }
    if try await SeasonNote.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil { return true }
    if try await NetflixMapping.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil { return true }
    return try await ImportEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$kind == title.kind)
        .filter(\.$tmdbID == title.tmdbID).first() != nil
}

/// One maintenance pass (part of the daily TMDB pass).
///
/// Stale titles (never refreshed, or last refreshed more than 60 days ago) are handled oldest first:
/// - titles nobody uses (see ``titleUsers(on:)``) are deleted with their episodes;
/// - titles with at least one user who has a TMDB token are re-fetched with one of those users' tokens (never a
///   stranger's), at most `refreshLimit` per pass;
/// - titles whose users have no token keep their data until 180 days without a refresh, then their TMDB texts are
///   cleared.
///
/// Finally, cached TMDB candidate lists of Netflix mappings and standard import entries older than 60 days are
/// discarded. Errors are logged, never thrown; a failed refresh of one title does not stop the pass.
/// - Parameters:
///   - db: The database holding the catalog.
///   - provider: Creates TMDB clients for user tokens.
///   - cipher: Decrypts the users' stored TMDB tokens.
///   - logger: Receives warnings and errors.
///   - now: The reference time for the age limits.
///   - refreshLimit: Maximum number of TMDB refreshes in this pass.
/// - Returns: What the pass refreshed, deleted and cleared.
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
                // Only the tokens of those who use the title, never a stranger's; the next one when TMDB rejects one.
                let ownerTokens = owners.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { tokens[$0] }
                if !ownerTokens.isEmpty {
                    guard result.refreshed < refreshLimit else { continue }
                    do {
                        if try await withAcceptedToken(ownerTokens, {
                            try await CatalogService(db: db, tmdb: provider.make($0)).refresh(title, now: now)
                        }) {
                            result.refreshed += 1
                        }
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
        for entry in try await ImportEntry.query(on: db).filter(\.$candidates != nil).all()
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
/// - Parameters:
///   - title: The cached title whose texts are cleared, together with its episodes' overviews and runtimes.
///   - db: The database to write to.
/// - Returns: `true` if any field was still set and has been cleared.
/// - Throws: Fluent's error for a title without ID, or database errors.
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
