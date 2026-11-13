import Fluent
import Vapor

struct TitleController {
    struct WatchInput: Content { var day: String?; var service: String?; var rewatch: String?; var open: String? }
    struct RatingInput: Content { var rating: String? }
    struct HiddenInput: Content { var hidden: Bool; var context: String? }
    struct CommentInput: Content { var comment: String? }
    struct FollowInput: Content { var followed: Bool; var context: String? }

    func register(on protected: any RoutesBuilder) {
        protected.get("tv", ":tmdbID", use: seriesPage)
        protected.post("tv", ":tmdbID", "episodes", ":season", ":number", "watch", use: markEpisode)
        protected.delete("tv", ":tmdbID", "episodes", ":season", ":number", "watch", use: unmarkEpisode)
        protected.post("tv", ":tmdbID", "episodes", ":season", ":number", "watch-up-to", use: markUpTo)
        protected.post("tv", ":tmdbID", "seasons", ":season", "watch", use: markSeason)
        protected.post("tv", ":tmdbID", "watch-all", use: markSeries)
        protected.post("tv", ":tmdbID", "hidden", use: setHidden)
        protected.post("tv", ":tmdbID", "follow", use: setFollowed)
        protected.post("tv", ":tmdbID", "new-episodes", "dismiss", use: dismissNewEpisodes)
        protected.post("tv", ":tmdbID", "rating") { try await setRating(req: $0, kind: .tv) }
        protected.post("tv", ":tmdbID", "comment") { try await setComment(req: $0, kind: .tv) }
        protected.post("tv", ":tmdbID", "seasons", ":season", "comment", use: setSeasonComment)
        protected.get("movie", ":tmdbID", use: moviePage)
        protected.post("movie", ":tmdbID", "watch", use: markMovie)
        protected.delete("movie", ":tmdbID", "watch", use: unmarkMovie)
        protected.post("movie", ":tmdbID", "rating") { try await setRating(req: $0, kind: .movie) }
        protected.post("movie", ":tmdbID", "comment") { try await setComment(req: $0, kind: .movie) }
    }

    // MARK: Series

    func seriesPage(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            await refreshForDetails(req, title)
            let userID = try req.userID
            let entry = try await findEntry(req, userID: userID, titleID: title.requireID())
            let seasons = try await seasonModels(req, title: title, userID: userID, open: nil)
            return HTMLResponse(SeriesPage(nav: try req.nav(.search), title: title, seasons: seasons, rating: entry?.rating,
                                           comment: entry?.comment, hidden: entry?.hidden ?? false, followed: entry?.isFollowed ?? false, today: req.watches.today(),
                                           defaultService: try await req.watches.lastService(userID: userID, titleID: title.requireID())))
        }
    }

    func markEpisode(req: Request) async throws -> Response {
        try await handle(req) {
            let (title, episode) = try await resolveEpisode(req)
            let userID = try req.userID
            let input = (try? req.content.decode(WatchInput.self)) ?? WatchInput()
            let service = try await serviceChoice(req, input.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markEpisode(userID: userID, episodeID: episode.requireID(), day: input.day,
                                                  service: service, rewatch: input.rewatch == "true")
            return try await seasonResponse(req, title: title, season: episode.season, userID: userID,
                                            openEpisode: input.open == "1" ? episode.number : nil)
        }
    }

    func unmarkEpisode(req: Request) async throws -> Response {
        try await handle(req) {
            let (title, episode) = try await resolveEpisode(req)
            let userID = try req.userID
            try await req.watches.unmarkEpisode(userID: userID, episodeID: episode.requireID())
            return try await seasonResponse(req, title: title, season: episode.season, userID: userID)
        }
    }

    func markSeason(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            guard let season = req.parameters.get("season", as: Int.self) else { throw Abort(.notFound) }
            let userID = try req.userID
            let service = try await serviceChoice(req, (try? req.content.decode(WatchInput.self))?.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markSeason(userID: userID, titleID: title.requireID(), season: season, service: service)
            return try await seasonResponse(req, title: title, season: season, userID: userID)
        }
    }

    func markSeries(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            let userID = try req.userID
            let service = try await serviceChoice(req, (try? req.content.decode(WatchInput.self))?.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markSeries(userID: userID, titleID: title.requireID(), service: service)
            let seasons = try await seasonModels(req, title: title, userID: userID, open: nil)
            return try await seasonsResponse(req, title: title, seasons: seasons, userID: userID)
        }
    }

    func markUpTo(req: Request) async throws -> Response {
        try await handle(req) {
            let (title, episode) = try await resolveEpisode(req)
            let userID = try req.userID
            let service = try await serviceChoice(req, (try? req.content.decode(WatchInput.self))?.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markUpTo(userID: userID, episodeID: episode.requireID(), service: service)
            var seasons = try await seasonModels(req, title: title, userID: userID, open: episode.season)
            // The button sits in the episode's details: they stay open.
            if let index = seasons.firstIndex(where: { $0.number == episode.season }) { seasons[index].openEpisode = episode.number }
            return try await seasonsResponse(req, title: title, seasons: seasons, userID: userID)
        }
    }

    func setHidden(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            let input = try req.content.decode(HiddenInput.self)
            try await req.watches.setHidden(userID: try req.userID, titleID: title.requireID(), hidden: input.hidden)
            if !input.hidden {
                do { try await req.catalog.refresh(title) } catch {
                    req.logger.warning("TMDB refresh after unhide failed for \(title.tmdbID): \(error)")
                }
            }
            if input.context == HiddenToggle.Context.card.rawValue {
                return HTMLResponse(EmptyHTML())
            }
            return HTMLResponse(HiddenToggle(tmdbID: title.tmdbID, hidden: input.hidden))
        }
    }

    // MARK: Movies

    func moviePage(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .movie)
            await refreshForDetails(req, title)
            let userID = try req.userID
            let entry = try await findEntry(req, userID: userID, titleID: title.requireID())
            return HTMLResponse(MoviePage(nav: try req.nav(.search), title: title,
                                          watches: try await movieWatches(req, userID: userID, titleID: title.requireID()),
                                          rating: entry?.rating, comment: entry?.comment, today: req.watches.today()))
        }
    }

    func markMovie(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .movie)
            let userID = try req.userID
            let input = (try? req.content.decode(WatchInput.self)) ?? WatchInput()
            let service = try await serviceChoice(req, input.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markMovie(userID: userID, titleID: title.requireID(), day: input.day, service: service,
                                                rewatch: input.rewatch == "true")
            return HTMLResponse(MovieWatchesSection(tmdbID: title.tmdbID, watches: try await movieWatches(req, userID: userID, titleID: title.requireID()),
                                                    today: req.watches.today()))
        }
    }

    func unmarkMovie(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .movie)
            let userID = try req.userID
            try await req.watches.unmarkMovie(userID: userID, titleID: title.requireID())
            return HTMLResponse(MovieWatchesSection(tmdbID: title.tmdbID, watches: [], today: req.watches.today()))
        }
    }

    // MARK: Rating

    func setRating(req: Request, kind: TitleKind) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, kind)
            let raw = (try? req.content.decode(RatingInput.self))?.rating?.trimmingCharacters(in: .whitespaces) ?? ""
            let rating: Int?
            if raw.isEmpty { rating = nil } else if let value = Int(raw) { rating = value } else { throw TrackingError.invalidRating }
            try await req.watches.setRating(userID: try req.userID, titleID: title.requireID(), rating: rating)
            return HTMLResponse(RatingControl(kind: kind, tmdbID: title.tmdbID, rating: rating))
        }
    }

    // MARK: Follow

    func setFollowed(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            let input = try req.content.decode(FollowInput.self)
            try await req.watches.setFollowed(userID: try req.userID, titleID: title.requireID(), followed: input.followed)
            if input.context == "account" { return HTMLResponse(EmptyHTML()) }   // row in the account list disappears
            return HTMLResponse(FollowToggle(tmdbID: title.tmdbID, followed: input.followed))
        }
    }

    func dismissNewEpisodes(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            try await req.watches.dismissNewEpisodes(userID: try req.userID, titleID: title.requireID())
            return HTMLResponse(EmptyHTML())
        }
    }

    // MARK: Comments

    func setComment(req: Request, kind: TitleKind) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, kind)
            let comment = (try? req.content.decode(CommentInput.self))?.comment
            let userID = try req.userID
            try await req.watches.setComment(userID: userID, titleID: title.requireID(), comment: comment)
            let saved = try await findEntry(req, userID: userID, titleID: title.requireID())?.comment
            let (id, label) = kind == .tv ? ("series-comment", "Kommentar zur Serie") : ("movie-comment", "Kommentar zum Film")
            return HTMLResponse(CommentBox(id: id, action: "/\(kind.rawValue)/\(title.tmdbID)/comment", caption: label, comment: saved, saved: true))
        }
    }

    func setSeasonComment(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            guard let season = req.parameters.get("season", as: Int.self) else { throw Abort(.notFound) }
            let comment = (try? req.content.decode(CommentInput.self))?.comment
            let userID = try req.userID
            try await req.watches.setSeasonComment(userID: userID, titleID: title.requireID(), season: season, comment: comment)
            let saved = try await req.watches.seasonComments(userID: userID, titleID: title.requireID())[season]
            return HTMLResponse(CommentBox(id: "season-comment-\(season)", action: "/tv/\(title.tmdbID)/seasons/\(season)/comment",
                                           caption: "Kommentar zur Staffel", comment: saved, saved: true))
        }
    }

    // MARK: Helpers

    private func refreshForDetails(_ req: Request, _ title: Title) async {
        await req.seriesDetails.refreshForDetails(title)
    }

    private func handle(_ req: Request, _ body: () async throws -> HTMLResponse) async throws -> Response {
        try await respondMappingTrackingErrors(req, body)
    }

    private func resolve(_ req: Request, _ kind: TitleKind) async throws -> Title {
        guard let tmdbID = req.parameters.get("tmdbID", as: Int.self) else { throw Abort(.notFound) }
        return try await req.catalog.title(kind: kind, tmdbID: tmdbID)
    }

    private func resolveEpisode(_ req: Request) async throws -> (Title, Episode) {
        let title = try await resolve(req, .tv)
        guard let season = req.parameters.get("season", as: Int.self), let number = req.parameters.get("number", as: Int.self),
              let episode = try await Episode.query(on: req.db).filter(\.$title.$id == title.requireID())
                .filter(\.$season == season).filter(\.$number == number).first() else { throw Abort(.notFound) }
        return (title, episode)
    }

    /// Absent field → last used service of this title; "" → unknown; otherwise must be a known service.
    private func serviceChoice(_ req: Request, _ raw: String?, userID: UUID, titleID: UUID) async throws -> StreamingService? {
        guard let raw else { return try await req.watches.lastService(userID: userID, titleID: titleID) }
        if raw.isEmpty { return nil }
        guard let service = StreamingService(rawValue: raw) else { throw Abort(.badRequest, reason: "Unbekannter Dienst") }
        return service
    }

    private func findEntry(_ req: Request, userID: UUID, titleID: UUID) async throws -> UserTitle? {
        try await req.seriesDetails.entry(userID: userID, titleID: titleID)
    }

    private func movieWatches(_ req: Request, userID: UUID, titleID: UUID) async throws -> [Watch] {
        try await req.seriesDetails.movieWatches(userID: userID, titleID: titleID)
    }

    private func seasonResponse(_ req: Request, title: Title, season: Int, userID: UUID,
                                openEpisode: Int? = nil) async throws -> HTMLResponse {
        let seasons = try await seasonModels(req, title: title, userID: userID, open: season)
        guard var model = seasons.first(where: { $0.number == season }) else { throw Abort(.notFound) }
        model.openEpisode = openEpisode
        let service = try await req.watches.lastService(userID: userID, titleID: title.requireID())
        return HTMLResponse(SeasonUpdate(
            section: SeasonSection(tmdbID: title.tmdbID, season: model, today: req.watches.today(), defaultService: service),
            refresh: BulkServiceRefresh(selected: service, seasons: seasons.map(\.number).filter { $0 != season })))
    }

    /// All seasons swapped, plus the series form's service choice (it sits outside `#seasons`).
    private func seasonsResponse(_ req: Request, title: Title, seasons: [SeasonModel], userID: UUID) async throws -> HTMLResponse {
        let service = try await req.watches.lastService(userID: userID, titleID: title.requireID())
        return HTMLResponse(SeasonUpdate(
            section: SeasonsList(tmdbID: title.tmdbID, seasons: seasons, today: req.watches.today(), defaultService: service),
            refresh: BulkServiceRefresh(selected: service, seasons: [])))
    }

    func seasonModels(_ req: Request, title: Title, userID: UUID, open: Int?) async throws -> [SeasonModel] {
        try await req.seriesDetails.seasons(title: title, userID: userID, open: open)
    }
}
