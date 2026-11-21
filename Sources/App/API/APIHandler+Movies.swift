import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/movies/{tmdbID}`: the movie's detail, refreshed first when stale or incomplete
    /// (`SeriesDetailService.refreshForDetails`, failures are only logged).
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.ok` with the movie detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   movie is neither cached for this user nor loadable from TMDB.
    func getMovie(_ input: Operations.getMovie.Input) async throws -> Operations.getMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        await request.seriesDetails.refreshForDetails(title)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    /// Handles `POST /api/v1/movies/{tmdbID}/watch`: records a watch via `WatchService.markMovie`.
    ///
    /// The optional body sets day, service (absent: the title's last used service, `unknown`: none) and `rewatch`.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional `WatchInput` body).
    /// - Returns: `.ok` with the updated movie detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` for an
    ///   unavailable movie, `TrackingError` date errors.
    func markMovie(_ input: Operations.markMovie.Input) async throws -> Operations.markMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let body: Components.Schemas.WatchInput? = if case let .json(value)? = input.body { value } else { nil }
        let service = try await Self.service(request, body?.service, user: user, title: title)
        _ = try await request.watches.markMovie(userID: user.requireID(), titleID: title.requireID(), day: body?.day, service: service,
                                                rewatch: body?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    /// Handles `DELETE /api/v1/movies/{tmdbID}/watch`: deletes the user's watches of the movie via
    /// `WatchService.unmarkMovie`.
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.ok` with the updated movie detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` for an
    ///   unavailable movie.
    func unmarkMovie(_ input: Operations.unmarkMovie.Input) async throws -> Operations.unmarkMovie.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        try await request.watches.unmarkMovie(userID: user.requireID(), titleID: title.requireID())
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/movies/{tmdbID}/rating`: sets or (without a rating) clears the user's rating via
    /// `WatchService.setRating`.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional body with `rating`).
    /// - Returns: `.ok` with the updated movie detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` for an
    ///   unavailable movie, `TrackingError.invalidRating`.
    func setMovieRating(_ input: Operations.setMovieRating.Input) async throws -> Operations.setMovieRating.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let rating: Int? = if case let .json(body)? = input.body { body.rating } else { nil }
        try await request.watches.setRating(userID: user.requireID(), titleID: title.requireID(), rating: rating)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/movies/{tmdbID}/comment`: sets or clears the user's comment via `WatchService.setComment`.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional body with `comment`).
    /// - Returns: `.ok` with the updated movie detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` for an
    ///   unavailable movie, `TrackingError.commentTooLong`.
    func setMovieComment(_ input: Operations.setMovieComment.Input) async throws -> Operations.setMovieComment.Output {
        let (request, user, title) = try await movieContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setComment(userID: user.requireID(), titleID: title.requireID(), comment: comment)
        return .ok(.init(body: .json(try await Self.movieDetail(request, user: user, title: title))))
    }

    /// Request, signed-in user and the movie (cached or fetched with the user's TMDB token).
    /// - Parameter tmdbID: The movie's TMDB ID.
    /// - Returns: The request, the user and the title.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   movie is neither cached for this user nor loadable from TMDB.
    private func movieContext(_ tmdbID: Int) async throws -> (Request, User, Title) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        return (request, user, try await request.catalog.title(kind: .movie, tmdbID: tmdbID))
    }

    /// Builds the `MovieDetail` schema with the user's rating, comment, watches and „Später ansehen“ (watch later)
    /// flag.
    /// - Parameters:
    ///   - request: The current request.
    ///   - user: The signed-in user.
    ///   - title: The movie.
    /// - Returns: The schema value.
    /// - Throws: Database errors.
    static func movieDetail(_ request: Request, user: User, title: Title) async throws -> Components.Schemas.MovieDetail {
        let titleID = try title.requireID()
        let entry = try await request.seriesDetails.entry(userID: user.requireID(), titleID: titleID)
        let watches = try await request.seriesDetails.movieWatches(userID: user.requireID(), titleID: titleID)
        return .init(tmdbId: title.tmdbID, name: title.name, year: title.year, posterPath: title.posterPath,
                     overview: title.overview.flatMap { $0.isEmpty ? nil : $0 }, runtime: title.runtime.flatMap { $0 > 0 ? $0 : nil },
                     genres: genres(title), links: links(title), rating: entry?.rating, comment: entry?.comment,
                     watchLater: try await request.watchLater.contains(userID: user.requireID(), titleID: titleID),
                     watches: watches.map(watchSummary))
    }
}
