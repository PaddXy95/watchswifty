import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getLibrary(_ input: Operations.getLibrary.Input) async throws -> Operations.getLibrary.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let items = try await LibraryService(db: request.db, watches: request.watches)
            .items(userID: user.requireID(), filter: input.query.filter?.rawValue ?? "all", sort: input.query.sort?.rawValue ?? "recent")
        return .ok(.init(body: .json(items.map { item in
            .init(kind: item.title.titleKind == .movie ? .movie : .tv, tmdbId: item.title.tmdbID, name: item.title.name,
                  posterPath: item.title.posterPath, rating: item.rating, hidden: item.hidden)
        })))
    }
}
