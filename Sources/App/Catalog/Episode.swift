import Fluent
import Foundation
import SQLKit

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
    /// Minutes; 0 = unknown, nil = not fetched yet.
    @OptionalField(key: "runtime") var runtime: Int?
    /// When a refresh first stored this episode (nil for rows from before notifications existed).
    @OptionalField(key: "first_seen_at") var firstSeenAt: Date?
    /// Time of the last refresh in which TMDB still returned this episode.
    @OptionalField(key: "last_seen_at") var lastSeenAt: Date?

    init() {}

    init(titleID: UUID, season: Int, number: Int, name: String, airDate: String?, tmdbEpisodeID: Int) {
        self.$title.id = titleID
        self.season = season
        self.number = number
        self.name = name
        self.airDate = airDate
        self.tmdbEpisodeID = tmdbEpisodeID
    }

    /// Still returned by the title's latest refresh (renumbered or dropped rows are not: refreshes never delete rows).
    func isCurrent(titleRefreshedAt: Date?) -> Bool {
        guard let lastSeenAt, let titleRefreshedAt else { return true }
        return lastSeenAt >= titleRefreshedAt
    }

    /// `S04E15`
    var code: String { String(format: "S%02dE%02d", season, number) }

    /// Lightweight episode list of several titles (no overview), read with a plain SQL projection: building ~13,000
    /// Fluent models made „Weiterschauen“ take about a second.
    static func infos(ofTitles titleIDs: [UUID], minSeason: Int = 0, on db: any Database) async throws -> [UUID: [EpisodeInfo]] {
        guard !titleIDs.isEmpty else { return [:] }
        guard let sql = db as? any SQLDatabase else {
            let episodes = try await Episode.query(on: db).filter(\.$title.$id ~~ titleIDs).filter(\.$season >= minSeason).all()
            return Dictionary(grouping: episodes, by: { $0.$title.id }).mapValues { $0.map(EpisodeInfo.init) }
        }
        struct Row: Decodable {
            let id: UUID
            let title_id: UUID
            let season_number: Int
            let episode_number: Int
            let name: String
            let air_date: String?
            let runtime: Int?
        }
        let rows = try await sql.select()
            .columns("id", "title_id", "season_number", "episode_number", "name", "air_date", "runtime")
            .from(Episode.schema)
            .where(SQLColumn("title_id"), .in, SQLBind.group(titleIDs))
            .where(SQLColumn("season_number"), .greaterThanOrEqual, SQLBind(minSeason))
            .all(decoding: Row.self)
        return Dictionary(grouping: rows, by: \.title_id).mapValues { list in
            list.map { EpisodeInfo(id: $0.id, season: $0.season_number, number: $0.episode_number, name: $0.name, airDate: $0.air_date,
                                   runtime: $0.runtime) }
        }
    }
}
