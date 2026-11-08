import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func search(_ input: Operations.search.Input) async throws -> Operations.search.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard request.tmdbToken != nil else { throw TMDBError.missingToken }
        let hits = try await SearchService(db: request.db, tmdb: request.tmdb).search(userID: user.requireID(), query: input.query.q)
        return .ok(.init(body: .json(hits.map { hit in
            .init(kind: hit.result.kind == .tv ? .tv : .movie, tmdbId: hit.result.id, name: hit.result.name, year: hit.result.year,
                  posterPath: hit.result.posterPath, inLibrary: hit.inLibrary, watchedEpisodes: hit.watchedEpisodes,
                  totalEpisodes: hit.totalEpisodes, rating: hit.rating)
        })))
    }

    static func searchResult(_ result: TMDBSearchResult) -> Components.Schemas.SearchResult {
        .init(kind: result.kind == .tv ? .tv : .movie, tmdbId: result.id, name: result.name, year: result.year, posterPath: result.posterPath)
    }
}
