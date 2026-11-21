import Fluent
import Vapor

/// „Später ansehen“: the page, adding from the search, removing from the page (spec §3).
struct WatchLaterController {
    struct AddInput: Content { var kind: String; var tmdbID: Int }

    func register(on protected: any RoutesBuilder) {
        protected.get("watch-later", use: page)
        protected.post("watch-later", use: add)
        protected.post("watch-later", ":kind", ":tmdbID", "remove", use: remove)
    }

    func page(req: Request) async throws -> HTMLResponse {
        let filter = (try? req.query.get(String.self, at: "filter")).flatMap { WatchLaterService.filters.contains($0) ? $0 : nil } ?? "all"
        let page = try await req.watchLater.page(user: try req.currentUser, filter: filter)
        return HTMLResponse(WatchLaterListPage(navContext: try req.nav(.watchLater), page: page, filter: filter))
    }

    func add(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(AddInput.self)
        guard let kind = TitleKind(rawValue: input.kind) else { throw Abort(.badRequest) }
        try await req.watchLater.add(userID: try req.userID, kind: kind, tmdbID: input.tmdbID, catalog: req.catalog,
                                     today: req.watches.today(), logger: req.logger)
        return HTMLResponse(SearchWatchLaterButton(kind: kind, tmdbID: input.tmdbID, onList: true))
    }

    /// Removes the entry; the card disappears (htmx swaps it with nothing). Not on the user's list → 404.
    func remove(req: Request) async throws -> HTMLResponse {
        guard let kind = req.parameters.get("kind").flatMap(TitleKind.init(rawValue:)),
              let tmdbID = req.parameters.get("tmdbID", as: Int.self),
              let title = try await Title.query(on: req.db).filter(\.$kind == kind.rawValue).filter(\.$tmdbID == tmdbID).first(),
              try await req.watchLater.contains(userID: try req.userID, titleID: title.requireID()) else { throw Abort(.notFound) }
        try await req.watchLater.remove(userID: try req.userID, titleID: title.requireID())
        return HTMLResponse(EmptyHTML())
    }
}
