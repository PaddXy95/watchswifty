import Fluent
import Vapor

struct LibraryController {
    func register(on protected: any RoutesBuilder) {
        protected.get("library", use: library)
    }

    func library(req: Request) async throws -> HTMLResponse {
        let rawFilter = (try? req.query.get(String.self, at: "filter")) ?? ""
        let rawSort = (try? req.query.get(String.self, at: "sort")) ?? ""
        let filter = LibraryService.filters.contains(rawFilter) ? rawFilter : "all"
        let sort = LibraryService.sorts.contains(rawSort) ? rawSort : "recent"
        let items = try await LibraryService(db: req.db, watches: req.watches).items(userID: try req.userID, filter: filter, sort: sort)
        return HTMLResponse(LibraryPage(navContext: try req.nav(.library), items: items, filter: filter, sort: sort))
    }
}
