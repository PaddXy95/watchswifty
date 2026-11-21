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

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates a pending mapping for a Netflix name.
    /// - Parameters:
    ///   - userID: The owner.
    ///   - netflixName: The show name or movie title as Netflix writes it.
    ///   - kind: Whether the name is looked up as a series or a movie.
    init(userID: UUID, netflixName: String, kind: TitleKind) {
        self.$user.id = userID
        self.netflixName = netflixName
        self.kind = kind.rawValue
        self.status = MappingStatus.pending.rawValue
    }

    /// The typed `kind`; unknown values read as `.tv`.
    var titleKind: TitleKind { TitleKind(rawValue: kind) ?? .tv }
    /// The typed `status`; unknown values read as `pending`.
    var mappingStatus: MappingStatus { MappingStatus(rawValue: status) ?? .pending }

    /// The decoded review candidates (empty when none or undecodable); setting them also stamps `candidatesAt`.
    var candidateResults: [TMDBSearchResult] {
        get { candidates.flatMap { try? JSONDecoder().decode([TMDBSearchResult].self, from: Data($0.utf8)) } ?? [] }
        set {
            candidates = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            candidatesAt = Date()
        }
    }
}
