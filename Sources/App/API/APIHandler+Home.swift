import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getContinueWatching(_ input: Operations.getContinueWatching.Input) async throws -> Operations.getContinueWatching.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let shelf = try await request.home.shelf(userID: user.requireID(), today: request.watches.today(), showAll: input.query.all ?? false)
        return .ok(.init(body: .json(.init(cards: shelf.cards.map(Self.card), olderCount: shelf.olderCount))))
    }

    func getNotes(_ input: Operations.getNotes.Input) async throws -> Operations.getNotes.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let notes = try await request.home.notes(userID: user.requireID(), today: request.watches.today())
        return .ok(.init(body: .json(.init(
            newEpisodes: notes.newEpisodes.map { .init(tmdbId: $0.tmdbID, name: $0.name, posterPath: $0.posterPath, count: $0.count,
                                                      first: Self.nextEpisode($0.first)) },
            upcoming: notes.upcoming.map { .init(tmdbId: $0.tmdbID, name: $0.name, count: $0.count, next: Self.nextEpisode($0.next)) }))))
    }

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

    func dismissNewEpisodes(_ input: Operations.dismissNewEpisodes.Input) async throws -> Operations.dismissNewEpisodes.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: .tv, tmdbID: input.path.tmdbID)
        try await request.watches.dismissNewEpisodes(userID: user.requireID(), titleID: title.requireID())
        return .noContent(.init())
    }

    static func nextEpisode(_ info: EpisodeInfo) -> Components.Schemas.NextEpisode {
        .init(episodeId: info.id.uuidString, season: info.season, number: info.number, name: info.name, airDate: info.airDate)
    }

    static func card(_ card: ContinueCard) -> Components.Schemas.ContinueCard {
        let link = card.watchService?.watchLink(for: card.name)
        return .init(tmdbId: card.tmdbID, name: card.name, posterPath: card.posterPath, rating: card.rating,
                     next: nextEpisode(card.next), remaining: card.remaining, lastWatchedOn: card.lastWatchedOn,
                     lastService: card.lastService.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) },
                     watchLink: link.map { .init(label: $0.label, url: $0.url) })
    }
}
