import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    // MARK: Operations

    func getSeries(_ input: Operations.getSeries.Input) async throws -> Operations.getSeries.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        await request.seriesDetails.refreshForDetails(title)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func markEpisode(_ input: Operations.markEpisode.Input) async throws -> Operations.markEpisode.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        let body = Self.watchInput(input.body)
        let service = try await Self.service(request, body?.service, user: user, title: title)
        _ = try await request.watches.markEpisode(userID: user.requireID(), episodeID: episode.requireID(), day: body?.day,
                                                  service: service, rewatch: body?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func unmarkEpisode(_ input: Operations.unmarkEpisode.Input) async throws -> Operations.unmarkEpisode.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        try await request.watches.unmarkEpisode(userID: user.requireID(), episodeID: episode.requireID())
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func markUpTo(_ input: Operations.markUpTo.Input) async throws -> Operations.markUpTo.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markUpTo(userID: user.requireID(), episodeID: episode.requireID(), service: service)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func markSeason(_ input: Operations.markSeason.Input) async throws -> Operations.markSeason.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markSeason(userID: user.requireID(), titleID: title.requireID(), season: input.path.season,
                                                 service: service)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func markSeries(_ input: Operations.markSeries.Input) async throws -> Operations.markSeries.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markSeries(userID: user.requireID(), titleID: title.requireID(), service: service)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func setHidden(_ input: Operations.setHidden.Input) async throws -> Operations.setHidden.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.watches.setHidden(userID: user.requireID(), titleID: title.requireID(), hidden: body.hidden)
        if !body.hidden {
            do { try await request.catalog.refresh(title) } catch {
                request.logger.warning("TMDB refresh after unhide failed for \(title.tmdbID): \(error)")
            }
        }
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func setFollowed(_ input: Operations.setFollowed.Input) async throws -> Operations.setFollowed.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.watches.setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: body.followed)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func setSeriesRating(_ input: Operations.setSeriesRating.Input) async throws -> Operations.setSeriesRating.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let rating: Int? = if case let .json(body)? = input.body { body.rating } else { nil }
        try await request.watches.setRating(userID: user.requireID(), titleID: title.requireID(), rating: rating)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func setSeriesComment(_ input: Operations.setSeriesComment.Input) async throws -> Operations.setSeriesComment.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setComment(userID: user.requireID(), titleID: title.requireID(), comment: comment)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    func setSeasonComment(_ input: Operations.setSeasonComment.Input) async throws -> Operations.setSeasonComment.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setSeasonComment(userID: user.requireID(), titleID: title.requireID(), season: input.path.season,
                                                   comment: comment)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    // MARK: Helpers

    /// Request, signed-in user and the series (cached or fetched with the user's TMDB token).
    private func seriesContext(_ tmdbID: Int) async throws -> (Request, User, Title) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        return (request, user, try await request.catalog.title(kind: .tv, tmdbID: tmdbID))
    }

    static func episode(_ request: Request, title: Title, season: Int, number: Int) async throws -> Episode {
        guard let episode = try await Episode.query(on: request.db).filter(\.$title.$id == title.requireID())
            .filter(\.$season == season).filter(\.$number == number).first() else { throw APIError.notFound }
        return episode
    }

    static func watchInput<Body>(_ body: Body?) -> Components.Schemas.WatchInput? {
        switch body {
        case let body as Operations.markEpisode.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markUpTo.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markSeason.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markSeries.Input.Body: if case let .json(value) = body { return value }
        default: break
        }
        return nil
    }

    /// Absent → last used service of this title; `unknown` → none; otherwise that service.
    static func service(_ request: Request, _ choice: Components.Schemas.WatchInput.servicePayload?, user: User,
                        title: Title) async throws -> StreamingService? {
        guard let choice else { return try await request.watches.lastService(userID: user.requireID(), titleID: title.requireID()) }
        return choice == .unknown ? nil : StreamingService(rawValue: choice.rawValue)
    }

    static func seriesDetail(_ request: Request, user: User, title: Title) async throws -> Components.Schemas.SeriesDetail {
        let model = try await request.seriesDetails.detail(userID: user.requireID(), title: title)
        return .init(
            tmdbId: title.tmdbID, name: title.name, year: title.year, posterPath: title.posterPath,
            overview: title.overview.flatMap { $0.isEmpty ? nil : $0 }, status: title.tmdbStatus,
            runtime: title.runtime.flatMap { $0 > 0 ? $0 : nil }, links: links(title),
            rating: model.rating, comment: model.comment, hidden: model.hidden, followed: model.followed,
            lastService: model.defaultService.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) },
            seasons: model.seasons.map { season in
                .init(number: season.number, title: season.title, watchedCount: season.watchedCount, comment: season.comment,
                      episodes: season.episodes.map { row in
                          .init(season: row.info.season, number: row.info.number, name: row.info.name, airDate: row.info.airDate,
                                overview: row.info.overview.flatMap { $0.isEmpty ? nil : $0 },
                                runtime: row.info.runtime.flatMap { $0 > 0 ? $0 : nil }, aired: row.aired,
                                watches: row.watches.map(watchSummary))
                      })
            })
    }

    static func links(_ title: Title) -> Components.Schemas.Links {
        let all = Dictionary(externalLinks(for: title).map { ($0.label, $0.url) }, uniquingKeysWith: { a, _ in a })
        return .init(tmdb: all["TMDB"] ?? "", imdb: all["IMDb"] ?? "", rottenTomatoes: all["Rotten Tomatoes"] ?? "",
                     seriesGraph: all["SeriesGraph"])
    }

    static func watchSummary(_ watch: Watch) -> Components.Schemas.WatchSummary {
        .init(id: watch.id?.uuidString ?? "", day: watch.watchedOn,
              service: watch.service.flatMap { Components.Schemas.Service(rawValue: $0) },
              origin: watch.watchOrigin == .import ? ._import : .manual)
    }
}
