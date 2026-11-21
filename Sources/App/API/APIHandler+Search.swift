import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/search`: searches TMDB for series and movies through `SearchService`, with the user's own
    /// state (library, „Später ansehen“ (watch later), progress, rating) per hit.
    /// - Parameter input: The generated operation input (query `q`).
    /// - Returns: `.ok` with the search hits.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token,
    ///   `TMDBError.missingToken` without a stored TMDB token, other `TMDBError`s from the search.
    func search(_ input: Operations.search.Input) async throws -> Operations.search.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard request.tmdbToken != nil else { throw TMDBError.missingToken }
        let hits = try await SearchService(db: request.db, tmdb: request.tmdb).search(userID: user.requireID(), query: input.query.q)
        return .ok(.init(body: .json(hits.map { hit in
            .init(kind: hit.result.kind == .tv ? .tv : .movie, tmdbId: hit.result.id, name: hit.result.name, year: hit.result.year,
                  posterPath: hit.result.posterPath, inLibrary: hit.inLibrary, watchLater: hit.watchLater, watchedEpisodes: hit.watchedEpisodes,
                  totalEpisodes: hit.totalEpisodes, rating: hit.rating)
        })))
    }

    /// Maps a TMDB search hit to the API's `SearchResult` schema (used for import and mapping candidates).
    /// - Parameter result: The TMDB hit.
    /// - Returns: The schema value.
    static func searchResult(_ result: TMDBSearchResult) -> Components.Schemas.SearchResult {
        .init(kind: result.kind == .tv ? .tv : .movie, tmdbId: result.id, name: result.name, year: result.year, posterPath: result.posterPath)
    }
}
