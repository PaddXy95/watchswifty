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
        let genre = (try? req.query.get(String.self, at: "genre")).flatMap(Genre.init(rawValue:))   // unknown → no filter
        let library = LibraryService(db: req.db)
        let userID = try req.userID
        let (items, genres) = try await library.page(userID: userID, filter: filter, sort: sort, genre: genre)
        return HTMLResponse(LibraryPage(navContext: try req.nav(.library), items: items, filter: filter, sort: sort, genre: genre,
                                        genres: genres))
    }
}
