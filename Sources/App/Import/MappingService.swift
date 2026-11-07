import Fluent
import Foundation
import Vapor

/// User decisions on the import page. Every method checks ownership (foreign IDs → `.notFound`).
struct MappingService {
    let db: any Database
    let catalog: CatalogService
    let watches: WatchService

    func accept(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws {
        let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
        let title = try await catalog.title(kind: kind, tmdbID: tmdbID)
        mapping.$title.id = try title.requireID()
        mapping.kind = kind.rawValue
        mapping.status = MappingStatus.confirmed.rawValue
        mapping.candidates = nil
        try await mapping.save(on: db)
        try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID)
            .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue, RowStatus.ignored.rawValue])
            .set(\.$status, to: RowStatus.pending.rawValue).update()
    }

    func ignore(userID: UUID, mappingID: UUID) async throws {
        let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
        mapping.status = MappingStatus.ignored.rawValue
        try await mapping.save(on: db)
        try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID)
            .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue])
            .set(\.$status, to: RowStatus.ignored.rawValue).update()
    }

    /// Deletes the import watches created from this name (manual watches it merged into stay),
    /// puts its rows back to pending and lets the worker resolve the name again.
    func reset(userID: UUID, mappingID: UUID) async throws {
        let mapping = try await ownMapping(userID: userID, mappingID: mappingID)
        let rows = try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID)
            .filter(\.$status != RowStatus.discarded.rawValue).all()
        let watchIDs = rows.compactMap(\.$watch.id)
        try await db.transaction { db in
            for row in rows {
                row.$watch.id = nil
                row.status = RowStatus.pending.rawValue
                try await row.save(on: db)
            }
            if !watchIDs.isEmpty {
                try await Watch.query(on: db).filter(\.$id ~~ watchIDs).filter(\.$origin == WatchOrigin.import.rawValue).delete()
            }
            mapping.$title.id = nil
            mapping.status = MappingStatus.pending.rawValue
            mapping.candidates = nil
            try await mapping.save(on: db)
        }
    }

    func change(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws {
        try await reset(userID: userID, mappingID: mappingID)
        try await accept(userID: userID, mappingID: mappingID, kind: kind, tmdbID: tmdbID)
    }

    func assignRow(userID: UUID, rowID: UUID, episodeID: UUID) async throws {
        let row = try await ownRow(userID: userID, rowID: rowID)
        guard let episode = try await Episode.find(episodeID, on: db) else { throw TrackingError.notFound }
        let watch = try await watches.recordImportedWatch(userID: userID, titleID: episode.$title.id, episodeID: episodeID, day: row.watchedOn)
        row.$watch.id = try watch.requireID()
        row.status = RowStatus.matched.rawValue
        try await row.save(on: db)
    }

    func ignoreRow(userID: UUID, rowID: UUID) async throws {
        let row = try await ownRow(userID: userID, rowID: rowID)
        row.status = RowStatus.ignored.rawValue
        try await row.save(on: db)
    }

    func ownMapping(userID: UUID, mappingID: UUID) async throws -> NetflixMapping {
        guard let mapping = try await NetflixMapping.query(on: db).filter(\.$id == mappingID).filter(\.$user.$id == userID).first() else {
            throw TrackingError.notFound
        }
        return mapping
    }

    private func ownRow(userID: UUID, rowID: UUID) async throws -> NetflixRow {
        guard let row = try await NetflixRow.query(on: db).filter(\.$id == rowID).filter(\.$user.$id == userID).first() else {
            throw TrackingError.notFound
        }
        return row
    }
}

extension Request {
    var mappings: MappingService { MappingService(db: db, catalog: catalog, watches: watches) }
}
