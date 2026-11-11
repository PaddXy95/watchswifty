import Fluent
import Foundation

/// Kinds of episode notices; `Comparable` by display priority (today first).
enum NoticeKind: String, Codable, CaseIterable, Sendable, Comparable {
    case announced, soon, today

    private var rank: Int {
        switch self {
        case .today: 0
        case .soon: 1
        case .announced: 2
        }
    }

    static func < (lhs: NoticeKind, rhs: NoticeKind) -> Bool { lhs.rank < rhs.rank }
}

/// One notice that went out to a user (so it is not sent again). `airDate` is the episode's date at the time:
/// „soon“/„today“ come again for a postponed episode. Does not count as using a title (`titleUsers`).
final class EpisodeNotice: Model, @unchecked Sendable {
    static let schema = "episode_notices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "episode_id") var episode: Episode
    @Field(key: "kind") var kind: String
    @OptionalField(key: "air_date") var airDate: String?
    @Field(key: "sent_at") var sentAt: Date

    init() {}

    init(userID: UUID, episodeID: UUID, kind: NoticeKind, airDate: String?, sentAt: Date) {
        self.$user.id = userID
        self.$episode.id = episodeID
        self.kind = kind.rawValue
        self.airDate = airDate
        self.sentAt = sentAt
    }
}

struct CreateEpisodeNotice: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EpisodeNotice.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("episode_id", .uuid, .required, .references(Episode.schema, .id, onDelete: .cascade))
            .field("kind", .string, .required)
            .field("air_date", .string)
            .field("sent_at", .datetime, .required)
            .unique(on: "user_id", "episode_id", "kind")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EpisodeNotice.schema).delete()
    }
}
