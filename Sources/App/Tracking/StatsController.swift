import Fluent
import Vapor

/// Web routes of the „Statistik“ (statistics) page.
struct StatsController {
    /// Registers the statistics route.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("stats", use: stats)
    }

    /// Serves `GET /stats`: renders the full statistics page, optionally for the year in the `year` query parameter.
    /// - Parameter req: The request.
    /// - Returns: The full „Statistik“ page.
    /// - Throws: An authentication error without a logged-in user, or database errors.
    func stats(req: Request) async throws -> HTMLResponse {
        let year = try? req.query.get(Int.self, at: "year")
        let stats = try await StatsService(db: req.db, today: req.application.appConfig.today())
            .stats(userID: try req.userID, year: year)
        return HTMLResponse(StatsPage(navContext: try req.nav(.stats), stats: stats))
    }
}
