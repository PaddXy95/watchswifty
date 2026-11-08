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

struct UpcomingNote: Sendable {
    let tmdbID: Int
    let name: String
    /// Next episode airing within the window.
    let next: EpisodeInfo
    /// Episodes of this series airing within the window.
    let count: Int
}

struct FollowedSeries: Sendable {
    let tmdbID: Int
    let name: String
    /// First regular episode airing after today, if TMDB knows one.
    let nextEpisode: EpisodeInfo?
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
        let episodesByTitle = try await Episode.infos(ofTitles: titleIDs, minSeason: 1, on: db)
        let watches = try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let watchesByTitle = Dictionary(grouping: watches, by: { $0.$title.id })
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })

        var notes: [NewEpisodesNote] = []
        for title in titles {
            guard let titleID = title.id, let entry = entryByTitle[titleID] else { continue }
            let titleWatches = watchesByTitle[titleID] ?? []
            let watched = Set(titleWatches.compactMap(\.$episode.id))
            let baseline = [entry.followedOn, entry.newSeenUntil, titleWatches.compactMap(\.watchedOn).max()].compactMap { $0 }.max() ?? ""
            let new = (episodesByTitle[titleID] ?? []).filter { episode in
                guard let airDate = episode.airDate else { return false }
                return airDate <= today && airDate > baseline && !watched.contains(episode.id)
            }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            guard let first = new.first else { continue }
            notes.append(NewEpisodesNote(titleID: titleID, tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath,
                                         count: new.count, first: first,
                                         newestAirDate: new.compactMap(\.airDate).max() ?? ""))
        }
        return notes.sorted { $0.newestAirDate > $1.newestAirDate }
    }

    /// „Demnächst“: followed series with regular episodes airing after today and at most `days` days ahead.
    func upcoming(userID: UUID, today: String, days: Int = 14) async throws -> [UpcomingNote] {
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$followed == true).all()
        guard !entries.isEmpty else { return [] }
        let titleIDs = entries.map(\.$title.id)
        let until = CalendarDay.adding(days: days, to: today)
        let titles = try await Title.query(on: db).filter(\.$id ~~ titleIDs).all()
        let episodes = try await Episode.query(on: db).filter(\.$title.$id ~~ titleIDs).filter(\.$season >= 1)
            .filter(\.$airDate > today).filter(\.$airDate <= until).all()
        let byTitle = Dictionary(grouping: episodes, by: { $0.$title.id })
        let notes: [UpcomingNote] = titles.compactMap { title in
            guard let id = title.id, let list = byTitle[id],
                  let next = list.min(by: { ($0.airDate ?? "", $0.season, $0.number) < ($1.airDate ?? "", $1.season, $1.number) }) else { return nil }
            return UpcomingNote(tmdbID: title.tmdbID, name: title.name, next: EpisodeInfo(next), count: list.count)
        }
        return notes.sorted { ($0.next.airDate ?? "") < ($1.next.airDate ?? "") }
    }

    /// All series the user follows (for the account page), by name.
    func followedSeries(userID: UUID, today: String) async throws -> [FollowedSeries] {
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$followed == true).all()
        guard !entries.isEmpty else { return [] }
        let titleIDs = entries.map(\.$title.id)
        let titles = try await Title.query(on: db).filter(\.$id ~~ titleIDs).all()
        let upcoming = try await Episode.query(on: db).filter(\.$title.$id ~~ titleIDs).filter(\.$season >= 1)
            .filter(\.$airDate > today).all()
        let nextByTitle = Dictionary(grouping: upcoming, by: { $0.$title.id }).compactMapValues { episodes in
            episodes.min { ($0.airDate ?? "", $0.season, $0.number) < ($1.airDate ?? "", $1.season, $1.number) }
        }
        return titles.map { title in
            FollowedSeries(tmdbID: title.tmdbID, name: title.name, nextEpisode: title.id.flatMap { nextByTitle[$0] }.map(EpisodeInfo.init))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
