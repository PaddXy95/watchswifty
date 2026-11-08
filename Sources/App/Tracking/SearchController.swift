import Fluent
import Vapor

struct SearchController {
    func register(on protected: any RoutesBuilder) {
        protected.get("search", use: page)
        protected.get("search", "results", use: results)
    }

    func page(req: Request) async throws -> HTMLResponse {
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        let hasToken = try hasToken(req)
        return HTMLResponse(SearchPage(nav: try req.nav(.search), query: query, hasToken: hasToken,
                                       results: hasToken ? try await search(req, query) : []))
    }

    func results(req: Request) async throws -> HTMLResponse {
        guard try hasToken(req) else { return HTMLResponse(SearchResults(results: [], hasToken: false)) }
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        return HTMLResponse(SearchResults(results: try await search(req, query), hasToken: true))
    }

    private func hasToken(_ req: Request) throws -> Bool {
        _ = try req.currentUser
        return req.tmdbToken != nil
    }

    private func search(_ req: Request, _ rawQuery: String) async throws -> [SearchResultModel] {
        try await SearchService(db: req.db, tmdb: req.tmdb).search(userID: try req.userID, query: rawQuery)
            .map { SearchResultModel(result: $0.result, status: $0.status, rating: $0.rating) }
    }
}
