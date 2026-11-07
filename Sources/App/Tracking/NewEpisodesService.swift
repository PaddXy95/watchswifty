import Fluent
import Foundation
import Vapor

struct NewEpisodesNote: Sendable {
    let titleID: UUID
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let count: Int
    /// First new episode (by season/number).
    let first: EpisodeInfo
    /// Air date of the most recent new episode (for sorting).
    let newestAirDate: String
}

/// „Neue Folgen“ for followed series: aired, unwatched regular episodes that aired after the
/// latest of follow start, last dated watch and last „Erledigt“.
struct NewEpisodesService {
    let db: any Database

    func notes(userID: UUID, today: String) async throws -> [NewEpisodesNote] {
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$followed == true).all()
        guard !entries.isEmpty else { return [] }
        let titleIDs = entries.map(\.$title.id)
        let titles = try await Title.query(on: db).filter(\.$id ~~ titleIDs).filter(\.$kind == TitleKind.tv.rawValue).all()
        let episodes = try await Episode.query(on: db).filter(\.$title.$id ~~ titleIDs).filter(\.$season >= 1).all()
        let watches = try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let episodesByTitle = Dictionary(grouping: episodes, by: { $0.$title.id })
        let watchesByTitle = Dictionary(grouping: watches, by: { $0.$title.id })
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })

        var notes: [NewEpisodesNote] = []
        for title in titles {
            guard let titleID = title.id, let entry = entryByTitle[titleID] else { continue }
            let titleWatches = watchesByTitle[titleID] ?? []
            let watched = Set(titleWatches.compactMap(\.$episode.id))
            let baseline = [entry.followedOn, entry.newSeenUntil, titleWatches.compactMap(\.watchedOn).max()].compactMap { $0 }.max() ?? ""
            let new = (episodesByTitle[titleID] ?? []).filter { episode in
                guard let airDate = episode.airDate, let id = episode.id else { return false }
                return airDate <= today && airDate > baseline && !watched.contains(id)
            }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            guard let first = new.first else { continue }
            notes.append(NewEpisodesNote(titleID: titleID, tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath,
                                         count: new.count, first: EpisodeInfo(first),
                                         newestAirDate: new.compactMap(\.airDate).max() ?? ""))
        }
        return notes.sorted { $0.newestAirDate > $1.newestAirDate }
    }
}
