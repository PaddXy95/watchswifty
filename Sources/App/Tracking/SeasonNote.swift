import Fluent
import Foundation

/// A user's private comment on one season of a series.
final class SeasonNote: Model, @unchecked Sendable {
    static let schema = "season_notes"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "title_id") var title: Title
    @Field(key: "season_number") var season: Int
    @Field(key: "comment") var comment: String

    init() {}

    init(userID: UUID, titleID: UUID, season: Int, comment: String) {
        self.$user.id = userID
        self.$title.id = titleID
        self.season = season
        self.comment = comment
    }
}
