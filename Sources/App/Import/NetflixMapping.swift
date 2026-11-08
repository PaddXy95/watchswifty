import Fluent
import Foundation

/// A user's decision which TMDB title a Netflix name (show or movie title) refers to.
final class NetflixMapping: Model, @unchecked Sendable {
    static let schema = "netflix_mappings"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "netflix_name") var netflixName: String
    @Field(key: "kind") var kind: String
    @OptionalParent(key: "title_id") var title: Title?
    @Field(key: "status") var status: String
    /// JSON-encoded `[TMDBSearchResult]` shown under „Zu prüfen“.
    @OptionalField(key: "candidates") var candidates: String?
    /// When the candidates were fetched (TMDB data may not be kept for long, see `CatalogMaintenance`).
    @OptionalField(key: "candidates_at") var candidatesAt: Date?

    init() {}

    init(userID: UUID, netflixName: String, kind: TitleKind) {
        self.$user.id = userID
        self.netflixName = netflixName
        self.kind = kind.rawValue
        self.status = MappingStatus.pending.rawValue
    }

    var titleKind: TitleKind { TitleKind(rawValue: kind) ?? .tv }
    var mappingStatus: MappingStatus { MappingStatus(rawValue: status) ?? .pending }

    var candidateResults: [TMDBSearchResult] {
        get { candidates.flatMap { try? JSONDecoder().decode([TMDBSearchResult].self, from: Data($0.utf8)) } ?? [] }
        set {
            candidates = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            candidatesAt = Date()
        }
    }
}
