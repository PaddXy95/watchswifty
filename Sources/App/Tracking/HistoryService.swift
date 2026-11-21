import Fluent
import Foundation
import Vapor

/// Dated watches, newest first, with title and episode loaded (web „Verlauf“ and `GET /v1/history`).
struct HistoryService {
    let db: any Database
    let watches: WatchService

    /// Highest page number considered (larger values would overflow the offset).
    static let maxPage = 1_000_000

    /// One page of the user's dated watches, newest day first (then newest recorded first); undated watches are left out.
    /// - Parameters:
    ///   - userID: The user.
    ///   - rawPage: The 1-based page number, clamped to 1…``maxPage``.
    ///   - perPage: The page size.
    /// - Returns: The page's watches with title and episode loaded, and the total number of dated watches.
    /// - Throws: Database errors.
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
    /// - Parameters:
    ///   - userID: The user; another user's watch counts as not found.
    ///   - watchID: The watch.
    ///   - day: The new day (`YYYY-MM-DD`), or nil to make the watch undated.
    ///   - service: The new service, or nil for none.
    /// - Returns: The saved watch.
    /// - Throws: `TrackingError.notFound`, `.invalidDate` or `.futureDate`.
    func edit(userID: UUID, watchID: UUID, day: String?, service: StreamingService?) async throws -> Watch {
        try await watches.editWatch(userID: userID, watchID: watchID, day: day, service: service)
        guard let watch = try await Watch.query(on: db).filter(\.$id == watchID).with(\.$title).with(\.$episode).first() else {
            throw TrackingError.notFound
        }
        return watch
    }
}

extension Request {
    /// The history service for this request.
    var history: HistoryService { HistoryService(db: db, watches: watches) }
}
