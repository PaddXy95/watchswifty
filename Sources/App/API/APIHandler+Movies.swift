import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getMovie(_ input: Operations.getMovie.Input) async throws -> Operations.getMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        await request.seriesDetails.refreshForDetails(title)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    func markMovie(_ input: Operations.markMovie.Input) async throws -> Operations.markMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let body: Components.Schemas.WatchInput? = if case let .json(value)? = input.body { value } else { nil }
        let service = try await Self.service(request, body?.service, user: user, title: title)
        _ = try await request.watches.markMovie(userID: user.requireID(), titleID: title.requireID(), day: body?.day, service: service,
                                                rewatch: body?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    func unmarkMovie(_ input: Operations.unmarkMovie.Input) async throws -> Operations.unmarkMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        try await request.watches.unmarkMovie(userID: user.requireID(), titleID: title.requireID())
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    func setMovieRating(_ input: Operations.setMovieRating.Input) async throws -> Operations.setMovieRating.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let rating: Int? = if case let .json(body)? = input.body { body.rating } else { nil }
        try await request.watches.setRating(userID: user.requireID(), titleID: title.requireID(), rating: rating)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    func setMovieComment(_ input: Operations.setMovieComment.Input) async throws -> Operations.setMovieComment.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setComment(userID: user.requireID(), titleID: title.requireID(), comment: comment)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    private func movieContext(_ tmdbID: Int) async throws -> (Request, User, Title) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        return (request, user, try await request.catalog.title(kind: .movie, tmdbID: tmdbID))
    }

    static func movieDetail(_ request: Request, user: User, title: Title) async throws -> Components.Schemas.MovieDetail {
        let titleID = try title.requireID()
        let entry = try await request.seriesDetails.entry(userID: user.requireID(), titleID: titleID)
        let watches = try await request.seriesDetails.movieWatches(userID: user.requireID(), titleID: titleID)
        return .init(tmdbId: title.tmdbID, name: title.name, year: title.year, posterPath: title.posterPath,
                     overview: title.overview.flatMap { $0.isEmpty ? nil : $0 }, runtime: title.runtime.flatMap { $0 > 0 ? $0 : nil },
                     links: links(title), rating: entry?.rating, comment: entry?.comment, watches: watches.map(watchSummary))
    }
}
