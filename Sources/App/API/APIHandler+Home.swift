import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/continue-watching`: the „Weiterschauen“ (continue watching) shelf from `HomeService.shelf`.
    /// - Parameter input: The generated operation input (query `all`: also return the older cards that are otherwise
    ///   only counted).
    /// - Returns: `.ok` with the cards and the number of older cards left out.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getContinueWatching(_ input: Operations.getContinueWatching.Input) async throws -> Operations.getContinueWatching.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let shelf = try await request.home.shelf(userID: user.requireID(), today: request.watches.today(), showAll: input.query.all ?? false)
        return .ok(.init(body: .json(.init(cards: shelf.cards.map(Self.card), olderCount: shelf.olderCount))))
    }

    /// Handles `GET /api/v1/notes`: the new-episode and upcoming-episode notes from `HomeService.notes`.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with both note lists.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getNotes(_ input: Operations.getNotes.Input) async throws -> Operations.getNotes.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let notes = try await request.home.notes(userID: user.requireID(), today: request.watches.today())
        return .ok(.init(body: .json(.init(
            newEpisodes: notes.newEpisodes.map { .init(tmdbId: $0.tmdbID, name: $0.name, posterPath: $0.posterPath, count: $0.count,
                                                      first: Self.nextEpisode($0.first)) },
            upcoming: notes.upcoming.map { .init(tmdbId: $0.tmdbID, name: $0.name, count: $0.count, next: Self.nextEpisode($0.next)) }))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/next`: marks the series' next episode watched (today, last used service) via
    /// `HomeService.markNext`.
    ///
    /// When the body names the episode the app showed and that is no longer the next one (double tap), nothing is
    /// marked.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional body with `episodeId`).
    /// - Returns: `.ok` with the updated card, or `.noContent` when the series is caught up.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `TrackingError` from marking.
    func markNextEpisode(_ input: Operations.markNextEpisode.Input) async throws -> Operations.markNextEpisode.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: .tv, tmdbID: input.path.tmdbID)
        let expected: UUID? = if case let .json(body)? = input.body { body.episodeId.flatMap(UUID.init(uuidString:)) } else { nil }
        guard let card = try await request.home.markNext(userID: user.requireID(), title: title, expectedEpisodeID: expected,
                                                          today: request.watches.today()) else {
            return .noContent(.init())
        }
        return .ok(.init(body: .json(Self.card(card))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/new-episodes/dismiss`: „Erledigt“ (done) on the new-episodes note via
    /// `WatchService.dismissNewEpisodes`.
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB.
    func dismissNewEpisodes(_ input: Operations.dismissNewEpisodes.Input) async throws -> Operations.dismissNewEpisodes.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: .tv, tmdbID: input.path.tmdbID)
        try await request.watches.dismissNewEpisodes(userID: user.requireID(), titleID: title.requireID())
        return .noContent(.init())
    }

    /// Maps an episode to the `NextEpisode` schema.
    /// - Parameter info: The episode.
    /// - Returns: The schema value.
    static func nextEpisode(_ info: EpisodeInfo) -> Components.Schemas.NextEpisode {
        .init(episodeId: info.id.uuidString, season: info.season, number: info.number, name: info.name, airDate: info.airDate)
    }

    /// Maps a continue-watching card to its schema, with the watch link of the last used service.
    /// - Parameter card: The card.
    /// - Returns: The schema value.
    static func card(_ card: ContinueCard) -> Components.Schemas.ContinueCard {
        let link = card.watchService?.watchLink(for: card.name)
        return .init(tmdbId: card.tmdbID, name: card.name, posterPath: card.posterPath, rating: card.rating,
                     next: nextEpisode(card.next), remaining: card.remaining, lastWatchedOn: card.lastWatchedOn,
                     lastService: card.lastService.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) },
                     watchLink: link.map { .init(label: $0.label, url: $0.url) })
    }
}
