import Fluent
import Vapor

struct SearchController {
    func register(on protected: any RoutesBuilder) {
        protected.get("search", use: page)
        protected.get("search", "results", use: results)
    }

    func page(req: Request) async throws -> HTMLResponse {
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        return HTMLResponse(SearchPage(nav: try req.nav(.search), query: query, results: try await search(req, query)))
    }

    func results(req: Request) async throws -> HTMLResponse {
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        return HTMLResponse(SearchResults(results: try await search(req, query)))
    }

    private func search(_ req: Request, _ rawQuery: String) async throws -> [SearchResultModel] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let results = try await req.tmdb.searchMulti(query)
        guard !results.isEmpty else { return [] }

        let userID = try req.userID
        let cached = try await Title.query(on: req.db).filter(\.$tmdbID ~~ results.map(\.id)).all()
            .filter { title in results.contains { $0.id == title.tmdbID && $0.kind == title.titleKind } }
        let titleIDs = try cached.map { try $0.requireID() }
        let watches = titleIDs.isEmpty ? [] : try await Watch.query(on: req.db)
            .filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let entries = titleIDs.isEmpty ? [] : try await UserTitle.query(on: req.db)
            .filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let episodes = titleIDs.isEmpty ? [] : try await Episode.query(on: req.db)
            .filter(\.$title.$id ~~ titleIDs).filter(\.$season >= 1).all()

        return results.map { result in
            guard let title = cached.first(where: { $0.tmdbID == result.id && $0.titleKind == result.kind }), let id = title.id else {
                return SearchResultModel(result: result, status: nil, rating: nil)
            }
            let own = watches.filter { $0.$title.id == id }
            let rating = entries.first { $0.$title.id == id }?.rating
            var status: String?
            if result.kind == .tv {
                let regular = Set(episodes.filter { $0.$title.id == id }.compactMap(\.id))
                let seen = Set(own.compactMap(\.$episode.id)).intersection(regular)
                if !seen.isEmpty { status = "\(seen.count)/\(regular.count) gesehen" }
            } else if !own.isEmpty {
                status = "gesehen"
            }
            return SearchResultModel(result: result, status: status, rating: rating)
        }
    }
}
