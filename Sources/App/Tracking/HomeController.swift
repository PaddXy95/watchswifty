import Fluent
import Vapor

/// Web routes of the start page („Weiterschauen“, continue watching).
struct HomeController {
    /// Registers the start page and the cards' „✓ gesehen“ (watched) button.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get(use: home)
        protected.post("tv", ":tmdbID", "next", use: markNext)
    }

    /// Serves `GET /`: renders the full „Weiterschauen“ page with the continue-watching cards and the „Neue Folgen“ (new
    /// episodes) and „Demnächst“ (upcoming) notes.
    ///
    /// Series inactive for longer than ``HomeService/cutoffMonths`` are hidden unless the query has `all=1`.
    /// - Parameter req: The request.
    /// - Returns: The full start page.
    /// - Throws: An authentication error without a logged-in user, or database errors.
    func home(req: Request) async throws -> HTMLResponse {
        let today = req.watches.today()
        let showAll = (try? req.query.get(String.self, at: "all")) == "1"
        let shelf = try await req.home.shelf(userID: try req.userID, today: today, showAll: showAll)
        let notes = try await req.home.notes(userID: try req.userID, today: today)
        return HTMLResponse(ContinuePage(nav: try req.nav(.continueWatching), cards: shelf.cards,
                                         hiddenCount: shelf.olderCount, showingAll: showAll,
                                         newEpisodes: notes.newEpisodes, upcoming: notes.upcoming))
    }

    /// Form body of `POST /tv/:tmdbID/next`.
    struct NextInput: Content { var episodeID: UUID? }

    /// Marks the card's next episode (today, last used service) and returns the updated card,
    /// or nothing when the series is caught up. When the request names the episode it saw
    /// (`episodeID`) and that is no longer the next one (double-click, second tab), nothing is marked.
    ///
    /// Serves `POST /tv/:tmdbID/next` (htmx).
    /// - Parameter req: The request; the route parameter `tmdbID` names the series.
    /// - Returns: The ``ContinueCardView`` fragment, or an empty fragment.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors when the series cannot be loaded, `TrackingError`
    ///   from marking the episode.
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
