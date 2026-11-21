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

    /// Creates an empty watch; required by Fluent.
    init() {}

    /// Creates a watch of an episode or a movie.
    /// - Parameters:
    ///   - userID: The user who watched.
    ///   - titleID: The series or movie.
    ///   - episodeID: The episode, or nil for a movie watch.
    ///   - watchedOn: The day watched (`YYYY-MM-DD`), or nil for an undated watch.
    ///   - service: The streaming service it was watched on, if known.
    ///   - origin: Whether the watch was entered by hand or imported.
    init(userID: UUID, titleID: UUID, episodeID: UUID?, watchedOn: String?, service: StreamingService?, origin: WatchOrigin) {
        self.$user.id = userID
        self.$title.id = titleID
        self.$episode.id = episodeID
        self.watchedOn = watchedOn
        self.service = service?.rawValue
        self.origin = origin.rawValue
    }

    /// The stored `service` as a ``StreamingService``; nil when unset or unknown.
    var streamingService: StreamingService? { service.flatMap(StreamingService.init(rawValue:)) }
    /// The stored `origin` as a ``WatchOrigin``; unknown values count as `.manual`.
    var watchOrigin: WatchOrigin { WatchOrigin(rawValue: origin) ?? .manual }
}
