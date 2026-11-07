import Fluent
import Foundation

/// One raw line of a user's Netflix export. Never deleted; its status records what happened to it.
final class NetflixRow: Model, @unchecked Sendable {
    static let schema = "netflix_rows"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "import_id") var netflixImport: NetflixImport
    @Field(key: "raw_title") var rawTitle: String
    @Field(key: "watched_on") var watchedOn: String
    @Field(key: "fingerprint") var fingerprint: String
    @Field(key: "parsed_kind") var parsedKind: String
    @OptionalField(key: "show_name") var showName: String?
    @OptionalField(key: "season_number") var seasonNumber: Int?
    @OptionalField(key: "episode_title") var episodeTitle: String?
    @Field(key: "status") var status: String
    @OptionalParent(key: "mapping_id") var mapping: NetflixMapping?
    @OptionalParent(key: "watch_id") var watch: Watch?

    init() {}

    init(userID: UUID, importID: UUID, row: NetflixCSVRow) {
        self.$user.id = userID
        self.$netflixImport.id = importID
        self.rawTitle = row.title
        self.watchedOn = row.day
        self.fingerprint = row.fingerprint
        switch parseNetflixTitle(row.title) {
        case let .episode(show, season, episodeTitle):
            self.parsedKind = "episode"
            self.showName = show
            self.seasonNumber = season
            self.episodeTitle = episodeTitle
        case .movie:
            self.parsedKind = "movie"
        }
        self.status = RowStatus.pending.rawValue
    }

    var rowStatus: RowStatus { RowStatus(rawValue: status) ?? .pending }
}
