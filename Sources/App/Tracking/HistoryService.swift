import Fluent
import Foundation
import Vapor

/// Dated watches, newest first, with title and episode loaded (web „Verlauf“ and `GET /v1/history`).
struct HistoryService {
    let db: any Database
    let watches: WatchService

    /// Highest page number considered (larger values would overflow the offset).
    static let maxPage = 1_000_000

    func page(userID: UUID, page rawPage: Int, perPage: Int) async throws -> (entries: [Watch], total: Int) {
        let page = min(max(1, rawPage), Self.maxPage)
        let query = watches.watchesQuery(userID: userID).filter(\.$watchedOn != nil)
        let total = try await query.count()
        let entries = try await watches.watchesQuery(userID: userID).filter(\.$watchedOn != nil)
            .sort(\.$watchedOn, .descending).sort(\.$createdAt, .descending)
            .offset((page - 1) * perPage).limit(perPage)
            .with(\.$title).with(\.$episode)
            .all()
        return (entries, total)
    }

    /// Edits a watch and returns it with title and episode loaded.
    func edit(userID: UUID, watchID: UUID, day: String?, service: StreamingService?) async throws -> Watch {
        try await watches.editWatch(userID: userID, watchID: watchID, day: day, service: service)
        guard let watch = try await Watch.query(on: db).filter(\.$id == watchID).with(\.$title).with(\.$episode).first() else {
            throw TrackingError.notFound
        }
        return watch
    }
}

extension Request {
    var history: HistoryService { HistoryService(db: db, watches: watches) }
}
