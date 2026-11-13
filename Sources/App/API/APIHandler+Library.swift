import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
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

    func startLibraryRefresh(_ input: Operations.startLibraryRefresh.Input) async throws -> Operations.startLibraryRefresh.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let token = request.application.tokenCipher.open(user.tmdbToken) else { throw TMDBError.missingToken }
        let state = try await request.application.libraryRefresh.start(userID: user.requireID(), token: token)
        return .accepted(.init(body: .json(Self.libraryRefresh(state))))
    }

    func getLibraryRefresh(_ input: Operations.getLibraryRefresh.Input) async throws -> Operations.getLibraryRefresh.Output {
        let user = try APIContext.requireUser()
        let state = try await APIContext.request().application.libraryRefresh.state(userID: user.requireID())
        return .ok(.init(body: .json(Self.libraryRefresh(state))))
    }

    static func libraryRefresh(_ state: LibraryRefreshState) -> Components.Schemas.LibraryRefresh {
        .init(running: state.running, done: state.done, total: state.total, failed: state.failed, finishedAt: state.finishedAt,
              error: state.error)
    }

    /// The title's genres for the API (empty while not loaded from TMDB).
    static func genres(_ title: Title) -> [Components.Schemas.Genre] {
        (title.genreList ?? []).compactMap { Components.Schemas.Genre(rawValue: $0.rawValue) }
    }
}
