import Fluent
import Vapor

/// „Später ansehen“: the page, adding from the search, removing from the page (spec §3).
struct WatchLaterController {
    /// Form body of `POST /watch-later`: title kind (`tv`/`movie`) and TMDB id.
    struct AddInput: Content { var kind: String; var tmdbID: Int }

    /// Registers the „Später ansehen“ routes.
    /// - Parameter protected: The route group requiring a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("watch-later", use: page)
        protected.post("watch-later", use: add)
        protected.post("watch-later", ":kind", ":tmdbID", "remove", use: remove)
    }

    /// `GET /watch-later`: renders the list page, filtered by the `filter` query parameter (`all`, `tv`, `movie`; anything
    /// else counts as `all`).
    /// - Parameter req: The request.
    /// - Returns: The ``WatchLaterListPage``.
    /// - Throws: Database errors, or an error when no user is logged in.
    func page(req: Request) async throws -> HTMLResponse {
        let filter = (try? req.query.get(String.self, at: "filter")).flatMap { WatchLaterService.filters.contains($0) ? $0 : nil } ?? "all"
        let page = try await req.watchLater.page(user: try req.currentUser, filter: filter)
        return HTMLResponse(WatchLaterListPage(navContext: try req.nav(.watchLater), page: page, filter: filter))
    }

    /// `POST /watch-later`: adds a title from the search to the list and returns the search result's button in its
    /// "on the list" state.
    /// - Parameter req: The request with an ``AddInput`` body.
    /// - Returns: The swapped ``SearchWatchLaterButton``.
    /// - Throws: `Abort(.badRequest)` for an unknown kind; catalog errors such as `TMDBError` when the title cannot be
    ///   loaded.
    func add(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(AddInput.self)
        guard let kind = TitleKind(rawValue: input.kind) else { throw Abort(.badRequest) }
        try await req.watchLater.add(userID: try req.userID, kind: kind, tmdbID: input.tmdbID, catalog: req.catalog,
                                     today: req.watches.today(), logger: req.logger)
        return HTMLResponse(SearchWatchLaterButton(kind: kind, tmdbID: input.tmdbID, onList: true))
    }

    /// Removes the entry; the card disappears (htmx swaps it with nothing). Not on the user's list → 404.
    ///
    /// Serves `POST /watch-later/:kind/:tmdbID/remove`.
    /// - Parameter req: The request.
    /// - Returns: An empty fragment.
    /// - Throws: `Abort(.notFound)` for an invalid path or a title not on the list, or database errors.
    func remove(req: Request) async throws -> HTMLResponse {
        guard let kind = req.parameters.get("kind").flatMap(TitleKind.init(rawValue:)),
              let tmdbID = req.parameters.get("tmdbID", as: Int.self),
              let title = try await Title.query(on: req.db).filter(\.$kind == kind.rawValue).filter(\.$tmdbID == tmdbID).first(),
              try await req.watchLater.contains(userID: try req.userID, titleID: title.requireID()) else { throw Abort(.notFound) }
        try await req.watchLater.remove(userID: try req.userID, titleID: title.requireID())
        return HTMLResponse(EmptyHTML())
    }
}
