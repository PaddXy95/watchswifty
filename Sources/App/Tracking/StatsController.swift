import Fluent
import Vapor

struct StatsController {
    func register(on protected: any RoutesBuilder) {
        protected.get("stats", use: stats)
    }

    func stats(req: Request) async throws -> HTMLResponse {
        let ratingYear = try? req.query.get(Int.self, at: "year")
        let stats = try await StatsService(db: req.db, today: req.application.appConfig.today())
            .stats(userID: try req.userID, ratingYear: ratingYear)
        return HTMLResponse(StatsPage(navContext: try req.nav(.stats), stats: stats, ratingYear: ratingYear))
    }
}
