import Fluent
import Foundation

/// One viewing of an episode (or of a movie when `episode` is nil) by one user.
final class Watch: Model, @unchecked Sendable {
    static let schema = "watches"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "title_id") var title: Title
    @OptionalParent(key: "episode_id") var episode: Episode?
    @OptionalField(key: "watched_on") var watchedOn: String?
    @OptionalField(key: "service") var service: String?
    @Field(key: "origin") var origin: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, titleID: UUID, episodeID: UUID?, watchedOn: String?, service: StreamingService?, origin: WatchOrigin) {
        self.$user.id = userID
        self.$title.id = titleID
        self.$episode.id = episodeID
        self.watchedOn = watchedOn
        self.service = service?.rawValue
        self.origin = origin.rawValue
    }

    var streamingService: StreamingService? { service.flatMap(StreamingService.init(rawValue:)) }
    var watchOrigin: WatchOrigin { WatchOrigin(rawValue: origin) ?? .manual }
}
