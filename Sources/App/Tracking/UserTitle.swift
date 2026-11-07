import Fluent
import Foundation

/// A title in one user's library: rating and hidden flag.
final class UserTitle: Model, @unchecked Sendable {
    static let schema = "user_titles"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "title_id") var title: Title
    @OptionalField(key: "rating") var rating: Int?
    @Field(key: "hidden") var hidden: Bool
    /// Private comment on the series or movie.
    @OptionalField(key: "comment") var comment: String?
    /// „Beobachten“: remind about new episodes.
    @OptionalField(key: "followed") var followed: Bool?
    @OptionalField(key: "followed_on") var followedOn: String?
    /// Day of the last „Erledigt“ on the new-episodes note.
    @OptionalField(key: "new_seen_until") var newSeenUntil: String?

    var isFollowed: Bool { followed ?? false }

    init() {}

    init(userID: UUID, titleID: UUID) {
        self.$user.id = userID
        self.$title.id = titleID
        self.hidden = false
    }
}
