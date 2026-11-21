import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/library`: the user's library from `LibraryService`.
    /// - Parameter input: The generated operation input (query `filter` (default `all`), `sort` (default `recent`),
    ///   optional `genre`).
    /// - Returns: `.ok` with the library items.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getLibrary(_ input: Operations.getLibrary.Input) async throws -> Operations.getLibrary.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let items = try await LibraryService(db: request.db)
            .items(userID: user.requireID(), filter: input.query.filter?.rawValue ?? "all", sort: input.query.sort?.rawValue ?? "recent",
                   genre: input.query.genre.flatMap { Genre(rawValue: $0.rawValue) })
        return .ok(.init(body: .json(items.map { item in
            .init(kind: item.title.titleKind == .movie ? .movie : .tv, tmdbId: item.title.tmdbID, name: item.title.name,
                  posterPath: item.title.posterPath, rating: item.rating, hidden: item.hidden, genres: Self.genres(item.title))
        })))
    }

    /// Handles `POST /api/v1/library/refresh`: starts reloading all library titles from TMDB with the user's token
    /// (`LibraryRefreshWorker`), or reports the run already going for this user.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.accepted` with the reload state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token,
    ///   `TMDBError.missingToken` without a readable TMDB token, database errors.
    func startLibraryRefresh(_ input: Operations.startLibraryRefresh.Input) async throws -> Operations.startLibraryRefresh.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let token = request.application.tokenCipher.open(user.tmdbToken) else { throw TMDBError.missingToken }
        let state = try await request.application.libraryRefresh.start(userID: user.requireID(), token: token)
        return .accepted(.init(body: .json(Self.libraryRefresh(state))))
    }

    /// Handles `GET /api/v1/library/refresh`: the state of the user's library reload (`LibraryRefreshWorker`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the reload state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token.
    func getLibraryRefresh(_ input: Operations.getLibraryRefresh.Input) async throws -> Operations.getLibraryRefresh.Output {
        let user = try APIContext.requireUser()
        let state = try await APIContext.request().application.libraryRefresh.state(userID: user.requireID())
        return .ok(.init(body: .json(Self.libraryRefresh(state))))
    }

    /// Maps a library reload state to the `LibraryRefresh` schema.
    /// - Parameter state: The worker's state for the user.
    /// - Returns: The schema value.
    static func libraryRefresh(_ state: LibraryRefreshState) -> Components.Schemas.LibraryRefresh {
        .init(running: state.running, done: state.done, total: state.total, failed: state.failed, finishedAt: state.finishedAt,
              error: state.error)
    }

    /// The title's genres for the API (empty while not loaded from TMDB).
    /// - Parameter title: The cached title.
    /// - Returns: The genres known to the API schema.
    static func genres(_ title: Title) -> [Components.Schemas.Genre] {
        (title.genreList ?? []).compactMap { Components.Schemas.Genre(rawValue: $0.rawValue) }
    }
}
