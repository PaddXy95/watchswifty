@testable import App
import Fluent
import VaporTesting

/// Inserts a series straight into the catalog (no TMDB). `seasons[n]` = episode count of season n.
/// All episodes aired on 2020-01-01 except `unaired` ("1x4" → 2999-01-01) and `noAirDate` (nil).
@discardableResult
func seedSeries(_ app: Application, tmdbID: Int, name: String = "Serie", seasons: [Int: Int],
                unaired: Set<String> = [], noAirDate: Set<String> = [], status: String? = "Returning Series") async throws -> Title {
    let title = Title(tmdbID: tmdbID, kind: .tv, name: name)
    title.tmdbStatus = status
    title.refreshedAt = .now
    try await title.save(on: app.db)
    for (season, count) in seasons.sorted(by: { $0.key < $1.key }) where count > 0 {
        for number in 1...count {
            let key = "\(season)x\(number)"
            let airDate: String? = noAirDate.contains(key) ? nil : (unaired.contains(key) ? "2999-01-01" : "2020-01-01")
            try await Episode(titleID: title.requireID(), season: season, number: number, name: "Folge \(key)",
                              airDate: airDate, tmdbEpisodeID: tmdbID * 10_000 + season * 100 + number).save(on: app.db)
        }
    }
    return title
}

@discardableResult
func seedMovie(_ app: Application, tmdbID: Int, name: String = "Film") async throws -> Title {
    let title = Title(tmdbID: tmdbID, kind: .movie, name: name)
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
