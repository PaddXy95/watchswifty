import Fluent
import Foundation
import SQLKit

/// The columns of a watch that „Statistik“, „Bibliothek“ and „Weiterschauen“ need, read as a plain SQL projection:
/// building thousands of Fluent `Watch` models took most of the time of these pages.
struct WatchRow: Sendable {
    let titleID: UUID
    let episodeID: UUID?
    let watchedOn: String?
    let service: StreamingService?
    let origin: WatchOrigin
    let createdAt: Date?

    /// The user's watches; `episodesOnly` leaves out movie watches, `titleID` limits them to one title.
    static func all(userID: UUID, episodesOnly: Bool = false, titleID: UUID? = nil, on db: any Database) async throws -> [WatchRow] {
        guard let sql = db as? any SQLDatabase else {
            var query = Watch.query(on: db).filter(\.$user.$id == userID)
            if episodesOnly { query = query.filter(\.$episode.$id != nil) }
            if let titleID { query = query.filter(\.$title.$id == titleID) }
            return try await query.all().map {
                WatchRow(titleID: $0.$title.id, episodeID: $0.$episode.id, watchedOn: $0.watchedOn, service: $0.streamingService,
                         origin: $0.watchOrigin, createdAt: $0.createdAt)
            }
        }
        struct Row: Decodable {
            let title_id: UUID
            let episode_id: UUID?
            let watched_on: String?
            let service: String?
            let origin: String
            /// Fluent stores timestamps as seconds since 1970.
            let created_at: Double?
        }
        var query = sql.select()
            .columns("title_id", "episode_id", "watched_on", "service", "origin", "created_at")
            .from(Watch.schema)
            .where(SQLColumn("user_id"), .equal, SQLBind(userID))
        if episodesOnly { query = query.where(SQLColumn("episode_id"), .isNot, SQLLiteral.null) }
        if let titleID { query = query.where(SQLColumn("title_id"), .equal, SQLBind(titleID)) }
        return try await query.all(decoding: Row.self).map { row in
            WatchRow(titleID: row.title_id, episodeID: row.episode_id, watchedOn: row.watched_on,
                     service: row.service.flatMap(StreamingService.init(rawValue:)),
                     origin: WatchOrigin(rawValue: row.origin) ?? .manual,
                     createdAt: row.created_at.map(Date.init(timeIntervalSince1970:)))
        }
    }
}
