import Fluent
import Vapor

struct HomeController {
    func register(on protected: any RoutesBuilder) {
        protected.get(use: home)
        protected.post("tv", ":tmdbID", "next", use: markNext)
    }

    func home(req: Request) async throws -> HTMLResponse {
        let cards = try await ContinueWatchingService(db: req.db).cards(userID: try req.userID, today: req.watches.today())
        return HTMLResponse(ContinuePage(nav: try req.nav(.continueWatching), cards: cards))
    }

    /// Marks the card's next episode (today, last used service) and returns the updated card,
    /// or nothing when the series is caught up.
    func markNext(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            guard let tmdbID = req.parameters.get("tmdbID", as: Int.self) else { throw Abort(.notFound) }
            let title = try await req.catalog.title(kind: .tv, tmdbID: tmdbID)
            let userID = try req.userID
            let service = ContinueWatchingService(db: req.db)
            let today = req.watches.today()
            guard let card = try await service.card(userID: userID, titleID: title.requireID(), today: today) else {
                return HTMLResponse(EmptyHTML())
            }
            _ = try await req.watches.markEpisode(userID: userID, episodeID: card.next.id, day: today,
                                                  service: try await req.watches.lastService(userID: userID, titleID: title.requireID()))
            if let updated = try await service.card(userID: userID, titleID: title.requireID(), today: today) {
                return HTMLResponse(ContinueCardView(card: updated))
            }
            return HTMLResponse(EmptyHTML())
        }
    }
}
