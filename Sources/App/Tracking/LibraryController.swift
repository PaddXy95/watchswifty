import Fluent
import Vapor

/// Web routes of the „Bibliothek“ (library) page.
struct LibraryController {
    /// Registers the library route.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("library", use: library)
    }

    /// Serves `GET /library`: renders the full library page.
    ///
    /// The `filter`, `sort` and `genre` query parameters are validated; unknown values fall back to all titles, most
    /// recently watched first, and no genre filter.
    /// - Parameter req: The request.
    /// - Returns: The full „Bibliothek“ page.
    /// - Throws: An authentication error without a logged-in user, or database errors.
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
