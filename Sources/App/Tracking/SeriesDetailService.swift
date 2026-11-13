import Fluent
import Foundation
import Vapor

/// Everything the series page (web) and `GET /v1/tv/{id}` (API) show, built in one place.
struct SeriesDetailModel {
    let title: Title
    let seasons: [SeasonModel]
    let rating: Int?
    let comment: String?
    let hidden: Bool
    let followed: Bool
    let defaultService: StreamingService?
}

struct SeriesDetailService {
    let db: any Database
    let catalog: CatalogService
    let watches: WatchService
    let logger: Logger

    /// Stale caches are refreshed; titles cached before overviews/runtimes/genres existed fetch them once.
    /// Failures (no token, TMDB down) only log – the cached data is shown.
    func refreshForDetails(_ title: Title) async {
        do {
            let episodesMissingOverview = title.titleKind == .tv
                ? try await Episode.query(on: db).filter(\.$title.$id == title.requireID()).filter(\.$overview == nil).count() > 0
                : false
            if title.overview == nil || title.runtime == nil || title.genres == nil || episodesMissingOverview {
                try await catalog.refresh(title)
            } else {
                try await catalog.refreshIfStale(title)
            }
        } catch {
            logger.warning("TMDB refresh failed for \(title.tmdbID): \(error)")
        }
    }

    func entry(userID: UUID, titleID: UUID) async throws -> UserTitle? {
        try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first()
    }

    /// A movie's watches, newest first.
    func movieWatches(userID: UUID, titleID: UUID) async throws -> [Watch] {
        try await watches.watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$episode.$id == nil)
            .sort(\.$watchedOn, .descending).sort(\.$createdAt, .descending).all()
    }

    func detail(userID: UUID, title: Title, open: Int? = nil) async throws -> SeriesDetailModel {
        let titleID = try title.requireID()
        let entry = try await entry(userID: userID, titleID: titleID)
        return SeriesDetailModel(title: title, seasons: try await seasons(title: title, userID: userID, open: open),
                                 rating: entry?.rating, comment: entry?.comment, hidden: entry?.hidden ?? false,
                                 followed: entry?.isFollowed ?? false,
                                 defaultService: try await watches.lastService(userID: userID, titleID: titleID))
    }

    /// Season view models; `open` forces a season open, otherwise the season of the next episode
    /// (or the first season when nothing is watched yet) is open.
    func seasons(title: Title, userID: UUID, open: Int?) async throws -> [SeasonModel] {
        let today = watches.today()
        let episodes = try await catalog.episodes(of: title.requireID())
        let watchList = try await watches.watchesQuery(userID: userID).filter(\.$title.$id == title.requireID())
            .filter(\.$episode.$id != nil).all()
        let byEpisode = Dictionary(grouping: watchList, by: { $0.$episode.id! }).mapValues { list in
            list.sorted { ($0.watchedOn ?? "", $0.createdAt ?? .distantPast) > ($1.watchedOn ?? "", $1.createdAt ?? .distantPast) }
        }
        let infos = episodes.map(EpisodeInfo.init)
        let openSeason = open ?? nextEpisode(in: infos, watched: Set(byEpisode.keys), today: today)?.season
            ?? (watchList.isEmpty ? infos.first(where: { $0.season >= 1 })?.season : nil)
        let grouped = Dictionary(grouping: episodes, by: \.season)
        let comments = try await watches.seasonComments(userID: userID, titleID: title.requireID())
        return grouped.keys.sorted { a, b in (a == 0 ? Int.max : a) < (b == 0 ? Int.max : b) }.map { number in
            SeasonModel(number: number, episodes: grouped[number]!.map { e in
                EpisodeRowModel(info: EpisodeInfo(e), aired: watches.isAired(e), watches: byEpisode[e.id!] ?? [])
            }, isOpen: number == openSeason, comment: comments[number])
        }
    }
}

extension Request {
    var seriesDetails: SeriesDetailService {
        SeriesDetailService(db: db, catalog: catalog, watches: watches, logger: logger)
    }
}
