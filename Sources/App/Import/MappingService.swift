import Fluent
import Foundation
import Vapor

/// User decisions on the import page. Every method checks ownership (foreign IDs → `.notFound`).
struct MappingService {
    let db: any Database
    let catalog: CatalogService
    let watches: WatchService
    /// Shared with the MatchingWorker so decisions and worker writes never interleave.
    let lock: AsyncMutex

    /// Confirms a reviewed name as the given TMDB title and puts its pending, unmatched and ignored rows back to pending.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - mappingID: The user's mapping.
    ///   - kind: Series or movie of the chosen title.
    ///   - tmdbID: The chosen TMDB ID (fetched into the catalog before taking the lock).
    /// - Throws: `TrackingError.notFound` for a foreign or unknown mapping, `TMDBError` from fetching the title.
    func accept(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws {
        _ = try await ownMapping(userID: userID, mappingID: mappingID)
        let titleID = try await catalog.title(kind: kind, tmdbID: tmdbID).requireID()   // TMDB outside the lock
        try await lock.withLock {
            let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
            try await confirm(mapping, kind: kind, titleID: titleID, on: db)
        }
    }

    /// Ignores a name: the mapping and its pending or unmatched rows become `ignored`.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - mappingID: The user's mapping.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown mapping.
    func ignore(userID: UUID, mappingID: UUID) async throws {
        try await lock.withLock {
            let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
            mapping.status = MappingStatus.ignored.rawValue
            try await mapping.save(on: db)
            try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID)
                .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue])
                .set(\.$status, to: RowStatus.ignored.rawValue).update()
        }
    }

    /// Deletes the import watches created from this name (manual watches it merged into stay),
    /// puts its rows back to pending and lets the worker resolve the name again.
    ///
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - mappingID: The user's mapping.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown mapping.
    func reset(userID: UUID, mappingID: UUID) async throws {
        try await lock.withLock {
            let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
            try await db.transaction { db in
                try await resetRows(of: mappingID, on: db)
                mapping.$title.id = nil
                mapping.status = MappingStatus.pending.rawValue
                mapping.candidates = nil
                try await mapping.save(on: db)
            }
        }
    }

    /// Re-points a name to another title in one step: the new title is fetched first (a TMDB
    /// failure leaves everything as it was), then rows are reset and the mapping is confirmed
    /// atomically — it never passes through `pending`, so the worker cannot re-resolve it.
    ///
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - mappingID: The user's mapping.
    ///   - kind: Series or movie of the new title.
    ///   - tmdbID: The new TMDB ID.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown mapping, `TMDBError` from fetching the title.
    func change(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws {
        _ = try await ownMapping(userID: userID, mappingID: mappingID)
        let titleID = try await catalog.title(kind: kind, tmdbID: tmdbID).requireID()
        try await lock.withLock {
            let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
            try await db.transaction { db in
                try await resetRows(of: mappingID, on: db)
                try await confirm(mapping, kind: kind, titleID: titleID, on: db)
            }
        }
    }

    /// Assigns an unmatched row to an episode by hand: records the imported watch and marks the row `matched`.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - rowID: The user's row.
    ///   - episodeID: The chosen episode.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown row or an unknown episode.
    func assignRow(userID: UUID, rowID: UUID, episodeID: UUID) async throws {
        try await lock.withLock {
            let row = try await ownRow(userID: userID, rowID: rowID)
            guard let episode = try await Episode.find(episodeID, on: db) else { throw TrackingError.notFound }
            let watch = try await watches.recordImportedWatch(userID: userID, titleID: episode.$title.id, episodeID: episodeID, day: row.watchedOn)
            row.$watch.id = try watch.requireID()
            row.status = RowStatus.matched.rawValue
            try await row.save(on: db)
        }
    }

    /// Marks a single row as `ignored`.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - rowID: The user's row.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown row.
    func ignoreRow(userID: UUID, rowID: UUID) async throws {
        try await lock.withLock {
            let row = try await ownRow(userID: userID, rowID: rowID)
            row.status = RowStatus.ignored.rawValue
            try await row.save(on: db)
        }
    }

    /// Sets the mapping to `confirmed` for the title (clearing candidates) and puts its pending, unmatched and ignored
    /// rows back to pending for the worker.
    /// - Parameters:
    ///   - mapping: The mapping to confirm.
    ///   - kind: Series or movie of the title.
    ///   - titleID: The cached title.
    ///   - db: The database (or transaction) to write to.
    /// - Throws: A database error.
    private func confirm(_ mapping: NetflixMapping, kind: TitleKind, titleID: UUID, on db: any Database) async throws {
        mapping.$title.id = titleID
        mapping.kind = kind.rawValue
        mapping.status = MappingStatus.confirmed.rawValue
        mapping.candidates = nil
        try await mapping.save(on: db)
        try await NetflixRow.query(on: db).filter(\.$mapping.$id == mapping.requireID())
            .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue, RowStatus.ignored.rawValue])
            .set(\.$status, to: RowStatus.pending.rawValue).update()
    }

    /// Puts all non-discarded rows of a mapping back to pending, unlinks their watches and deletes those watches that
    /// came from the import (merged manual watches stay).
    /// - Parameters:
    ///   - mappingID: The mapping whose rows are reset.
    ///   - db: The database (or transaction) to write to.
    /// - Throws: A database error.
    private func resetRows(of mappingID: UUID, on db: any Database) async throws {
        let rows = try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID)
            .filter(\.$status != RowStatus.discarded.rawValue).all()
        let watchIDs = rows.compactMap(\.$watch.id)
        for row in rows {
            row.$watch.id = nil
            row.status = RowStatus.pending.rawValue
            try await row.save(on: db)
        }
        if !watchIDs.isEmpty {
            try await Watch.query(on: db).filter(\.$id ~~ watchIDs).filter(\.$origin == WatchOrigin.import.rawValue).delete()
        }
    }

    /// Loads a mapping through its owner.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - mappingID: The mapping to load.
    /// - Returns: The user's mapping.
    /// - Throws: `TrackingError.notFound` when it does not exist or belongs to someone else.
    func ownMapping(userID: UUID, mappingID: UUID) async throws -> NetflixMapping {
        guard let mapping = try await NetflixMapping.query(on: db).filter(\.$id == mappingID).filter(\.$user.$id == userID).first() else {
            throw TrackingError.notFound
        }
        return mapping
    }

    /// Loads a Netflix row through its owner.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - rowID: The row to load.
    /// - Returns: The user's row.
    /// - Throws: `TrackingError.notFound` when it does not exist or belongs to someone else.
    func ownRow(userID: UUID, rowID: UUID) async throws -> NetflixRow {
        guard let row = try await NetflixRow.query(on: db).filter(\.$id == rowID).filter(\.$user.$id == userID).first() else {
            throw TrackingError.notFound
        }
        return row
    }
}

extension Request {
    /// Mapping decisions for this request, sharing the app's import lock with the `MatchingWorker`.
    var mappings: MappingService { MappingService(db: db, catalog: catalog, watches: watches, lock: application.importLock) }
}
