import Fluent
import Foundation

/// Shared TMDB cache entry for a series or movie (not user data).
final class Title: Model, @unchecked Sendable {
    static let schema = "titles"

    @ID(key: .id) var id: UUID?
    @Field(key: "tmdb_id") var tmdbID: Int
    @Field(key: "kind") var kind: String
    @Field(key: "name") var name: String
    @OptionalField(key: "original_name") var originalName: String?
    @OptionalField(key: "year") var year: Int?
    @OptionalField(key: "poster_path") var posterPath: String?
    @OptionalField(key: "tmdb_status") var tmdbStatus: String?
    @OptionalField(key: "refreshed_at") var refreshedAt: Date?
    /// TMDB overview („Klappentext“); "" = TMDB has none, nil = not fetched yet.
    @OptionalField(key: "overview") var overview: String?
    /// IMDb id (e.g. tt0944947); "" = none, nil = not fetched yet.
    @OptionalField(key: "imdb_id") var imdbID: String?

    init() {}

    init(tmdbID: Int, kind: TitleKind, name: String) {
        self.tmdbID = tmdbID
        self.kind = kind.rawValue
        self.name = name
    }

    var titleKind: TitleKind { TitleKind(rawValue: kind) ?? .tv }
}
