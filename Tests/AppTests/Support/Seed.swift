@testable import App
import Fluent
import VaporTesting

/// Inserts a series straight into the catalog (no TMDB). `seasons[n]` = episode count of season n.
/// All episodes aired on 2020-01-01 except `unaired` ("1x4" → 2999-01-01) and `noAirDate` (nil).
@discardableResult
func seedSeries(_ app: Application, tmdbID: Int, name: String = "Serie", seasons: [Int: Int],
                unaired: Set<String> = [], noAirDate: Set<String> = [], airDates: [String: String] = [:],
                status: String? = "Returning Series", runtime: Int? = nil,
                episodeRuntimes: [String: Int] = [:], genres: String? = "") async throws -> Title {
    let title = Title(tmdbID: tmdbID, kind: .tv, name: name)
    title.tmdbStatus = status
    title.runtime = runtime
    title.genres = genres
    title.refreshedAt = .now
    try await title.save(on: app.db)
    for (season, count) in seasons.sorted(by: { $0.key < $1.key }) where count > 0 {
        for number in 1...count {
            let key = "\(season)x\(number)"
            let airDate: String? = airDates[key] ?? (noAirDate.contains(key) ? nil : (unaired.contains(key) ? "2999-01-01" : "2020-01-01"))
            let episode = Episode(titleID: try title.requireID(), season: season, number: number, name: "Folge \(key)",
                                  airDate: airDate, tmdbEpisodeID: tmdbID * 10_000 + season * 100 + number)
            episode.runtime = episodeRuntimes[key]
            try await episode.save(on: app.db)
        }
    }
    return title
}

@discardableResult
func seedMovie(_ app: Application, tmdbID: Int, name: String = "Film", runtime: Int? = nil,
               genres: String? = "") async throws -> Title {
    let title = Title(tmdbID: tmdbID, kind: .movie, name: name)
    title.runtime = runtime
    title.genres = genres
    title.refreshedAt = .now
    try await title.save(on: app.db)
    return title
}

func episode(_ app: Application, _ title: Title, _ season: Int, _ number: Int) async throws -> Episode {
    guard let episode = try await Episode.query(on: app.db).filter(\.$title.$id == title.requireID())
        .filter(\.$season == season).filter(\.$number == number).first() else {
        fatalError("no episode \(season)x\(number)")
    }
    return episode
}
