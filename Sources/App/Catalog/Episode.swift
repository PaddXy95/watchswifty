import Fluent
import Foundation

/// Shared TMDB cache entry for one episode. Never deleted by refreshes (watches point here).
final class Episode: Model, @unchecked Sendable {
    static let schema = "episodes"

    @ID(key: .id) var id: UUID?
    @Parent(key: "title_id") var title: Title
    @Field(key: "season_number") var season: Int
    @Field(key: "episode_number") var number: Int
    @Field(key: "name") var name: String
    @OptionalField(key: "air_date") var airDate: String?
    @Field(key: "tmdb_episode_id") var tmdbEpisodeID: Int
    /// TMDB overview of the episode; "" = none, nil = not fetched yet.
    @OptionalField(key: "overview") var overview: String?

    init() {}

    init(titleID: UUID, season: Int, number: Int, name: String, airDate: String?, tmdbEpisodeID: Int) {
        self.$title.id = titleID
        self.season = season
        self.number = number
        self.name = name
        self.airDate = airDate
        self.tmdbEpisodeID = tmdbEpisodeID
    }

    /// `S04E15`
    var code: String { String(format: "S%02dE%02d", season, number) }
}
