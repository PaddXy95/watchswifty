import Fluent
import Vapor

/// Web routes of the TMDB search („Suche“).
struct SearchController {
    /// Registers the search page and its live-results fragment.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("search", use: page)
        protected.get("search", "results", use: results)
    }

    /// Serves `GET /search`: renders the full search page, with results for the `q` query parameter when the user has a
    /// TMDB token.
    /// - Parameter req: The request.
    /// - Returns: The full search page.
    /// - Throws: An authentication error without a logged-in user, or TMDB and database errors.
    func page(req: Request) async throws -> HTMLResponse {
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        let hasToken = try hasToken(req)
        return HTMLResponse(SearchPage(nav: try req.nav(.search), query: query, hasToken: hasToken,
                                       results: hasToken ? try await search(req, query) : []))
    }

    /// Serves `GET /search/results`: the htmx fragment with the results for the `q` query parameter (a hint instead when
    /// the user has no TMDB token).
    /// - Parameter req: The request.
    /// - Returns: The results fragment.
    /// - Throws: An authentication error without a logged-in user, or TMDB and database errors.
    func results(req: Request) async throws -> HTMLResponse {
        guard try hasToken(req) else { return HTMLResponse(SearchResults(results: [], hasToken: false)) }
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        return HTMLResponse(SearchResults(results: try await search(req, query), hasToken: true))
    }

    /// Whether the logged-in user has a TMDB token to search with.
    /// - Parameter req: The request.
    /// - Returns: True when `req.tmdbToken` is set.
    /// - Throws: An authentication error without a logged-in user.
    private func hasToken(_ req: Request) throws -> Bool {
        _ = try req.currentUser
        return req.tmdbToken != nil
    }

    /// Runs the search for the logged-in user and maps the hits to view models.
    /// - Parameters:
    ///   - req: The request.
    ///   - rawQuery: The query as typed; ``SearchService`` trims it and ignores queries shorter than 2 characters.
    /// - Returns: The result view models.
    /// - Throws: TMDB and database errors.
    private func search(_ req: Request, _ rawQuery: String) async throws -> [SearchResultModel] {
        try await SearchService(db: req.db, tmdb: req.tmdb).search(userID: try req.userID, query: rawQuery)
            .map { SearchResultModel(result: $0.result, status: $0.status, rating: $0.rating, watchLater: $0.watchLater) }
    }
}
