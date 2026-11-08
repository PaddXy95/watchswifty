import Fluent
import Vapor

struct HomeController {
    func register(on protected: any RoutesBuilder) {
        protected.get(use: home)
        protected.post("tv", ":tmdbID", "next", use: markNext)
    }

    func home(req: Request) async throws -> HTMLResponse {
        let today = req.watches.today()
        let showAll = (try? req.query.get(String.self, at: "all")) == "1"
        let shelf = try await req.home.shelf(userID: try req.userID, today: today, showAll: showAll)
        let notes = try await req.home.notes(userID: try req.userID, today: today)
        return HTMLResponse(ContinuePage(nav: try req.nav(.continueWatching), cards: shelf.cards,
                                         hiddenCount: shelf.olderCount, showingAll: showAll,
                                         newEpisodes: notes.newEpisodes, upcoming: notes.upcoming))
    }

    struct NextInput: Content { var episodeID: UUID? }

    /// Marks the card's next episode (today, last used service) and returns the updated card,
    /// or nothing when the series is caught up. When the request names the episode it saw
    /// (`episodeID`) and that is no longer the next one (double-click, second tab), nothing is marked.
    func markNext(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            guard let tmdbID = req.parameters.get("tmdbID", as: Int.self) else { throw Abort(.notFound) }
            let title = try await req.catalog.title(kind: .tv, tmdbID: tmdbID)
            let expected = (try? req.content.decode(NextInput.self))?.episodeID
            if let updated = try await req.home.markNext(userID: try req.userID, title: title, expectedEpisodeID: expected,
                                                         today: req.watches.today()) {
                return HTMLResponse(ContinueCardView(card: updated))
            }
            return HTMLResponse(EmptyHTML())
        }
    }
}
