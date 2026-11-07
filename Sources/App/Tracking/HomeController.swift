import Fluent
import Vapor

struct HomeController {
    func register(on protected: any RoutesBuilder) {
        protected.get(use: home)
        protected.post("tv", ":tmdbID", "next", use: markNext)
    }

    /// Series inactive for longer than this are hidden unless `?all=1`.
    static let cutoffMonths = 3

    func home(req: Request) async throws -> HTMLResponse {
        let today = req.watches.today()
        let cards = try await ContinueWatchingService(db: req.db).cards(userID: try req.userID, today: today)
        let showAll = (try? req.query.get(String.self, at: "all")) == "1"
        let cutoff = CalendarDay.adding(months: -Self.cutoffMonths, to: today)
        let visible = showAll ? cards : cards.filter { $0.lastActivityOn >= cutoff }
        return HTMLResponse(ContinuePage(nav: try req.nav(.continueWatching), cards: visible,
                                         hiddenCount: cards.count - visible.count, showingAll: showAll))
    }

    struct NextInput: Content { var episodeID: UUID? }

    /// Marks the card's next episode (today, last used service) and returns the updated card,
    /// or nothing when the series is caught up. When the request names the episode it saw
    /// (`episodeID`) and that is no longer the next one (double-click, second tab), nothing is marked.
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
            let expected = (try? req.content.decode(NextInput.self))?.episodeID
            if expected == nil || expected == card.next.id {
                _ = try await req.watches.markEpisode(userID: userID, episodeID: card.next.id, day: today,
                                                      service: try await req.watches.lastService(userID: userID, titleID: title.requireID()))
            }
            if let updated = try await service.card(userID: userID, titleID: title.requireID(), today: today) {
                return HTMLResponse(ContinueCardView(card: updated))
            }
            return HTMLResponse(EmptyHTML())
        }
    }
}
