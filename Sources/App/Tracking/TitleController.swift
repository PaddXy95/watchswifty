import Fluent
import Vapor

/// Web routes of the series and movie pages (`/tv/:tmdbID`, `/movie/:tmdbID`) and of all tracking actions on them.
///
/// Every action resolves the title by its TMDB ID through the catalog (fetching it from TMDB when not cached) and
/// writes only the logged-in user's own records.
struct TitleController {
    /// Form body of the watch actions: day (empty = today), service (absent = last used, empty = none), `rewatch=true`
    /// for a new viewing or round, and `open=1` to keep the episode's details expanded.
    struct WatchInput: Content { var day: String?; var service: String?; var rewatch: String?; var open: String? }
    /// Form body of the rating actions: 1…10, or empty to remove the rating.
    struct RatingInput: Content { var rating: String? }
    /// Form body of `POST /tv/:tmdbID/hidden`; `context` is a ``HiddenToggle/Context`` raw value.
    struct HiddenInput: Content { var hidden: Bool; var context: String? }
    /// Form body of the comment actions; an empty comment removes it.
    struct CommentInput: Content { var comment: String? }
    /// Form body of `POST /tv/:tmdbID/follow`; `context` `account` when sent from the account page's list.
    struct FollowInput: Content { var followed: Bool; var context: String? }
    /// Form body of the „Später ansehen“ (watch later) toggles.
    struct WatchLaterInput: Content { var watchLater: Bool }

    /// Registers the title page and tracking routes.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("tv", ":tmdbID", use: seriesPage)
        protected.post("tv", ":tmdbID", "episodes", ":season", ":number", "watch", use: markEpisode)
        protected.delete("tv", ":tmdbID", "episodes", ":season", ":number", "watches", ":watchID", use: deleteEpisodeWatch)
        protected.post("tv", ":tmdbID", "episodes", ":season", ":number", "watch-up-to", use: markUpTo)
        protected.post("tv", ":tmdbID", "seasons", ":season", "watch", use: markSeason)
        protected.post("tv", ":tmdbID", "watch-all", use: markSeries)
        protected.post("tv", ":tmdbID", "hidden", use: setHidden)
        protected.post("tv", ":tmdbID", "follow", use: setFollowed)
        protected.post("tv", ":tmdbID", "new-episodes", "dismiss", use: dismissNewEpisodes)
        protected.post("tv", ":tmdbID", "rating") { try await setRating(req: $0, kind: .tv) }
        protected.post("tv", ":tmdbID", "comment") { try await setComment(req: $0, kind: .tv) }
        protected.post("tv", ":tmdbID", "seasons", ":season", "comment", use: setSeasonComment)
        protected.post("tv", ":tmdbID", "watch-later") { try await setWatchLater(req: $0, kind: .tv) }
        protected.get("tv", ":tmdbID", "availability") { try await availability(req: $0, kind: .tv) }
        protected.get("movie", ":tmdbID", use: moviePage)
        protected.post("movie", ":tmdbID", "watch-later") { try await setWatchLater(req: $0, kind: .movie) }
        protected.get("movie", ":tmdbID", "availability") { try await availability(req: $0, kind: .movie) }
        protected.post("movie", ":tmdbID", "watch", use: markMovie)
        protected.delete("movie", ":tmdbID", "watches", ":watchID", use: deleteMovieWatch)
        protected.post("movie", ":tmdbID", "rating") { try await setRating(req: $0, kind: .movie) }
        protected.post("movie", ":tmdbID", "comment") { try await setComment(req: $0, kind: .movie) }
    }

    // MARK: Series

    /// Serves `GET /tv/:tmdbID`: refreshes stale TMDB data (failures only log) and renders the full series page with
    /// seasons, the user's watches, rating, comment, flags and the availability block.
    /// - Parameter req: The request.
    /// - Returns: The full series page.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors when the series cannot be loaded.
    func seriesPage(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            await refreshForDetails(req, title)
            let userID = try req.userID
            let entry = try await findEntry(req, userID: userID, titleID: title.requireID())
            let seasons = try await seasonModels(req, title: title, userID: userID, open: nil)
            let onList = try await req.watchLater.contains(userID: userID, titleID: title.requireID())
            return HTMLResponse(SeriesPage(nav: try req.nav(.search), title: title, seasons: seasons, rating: entry?.rating,
                                           comment: entry?.comment, hidden: entry?.hidden ?? false, followed: entry?.isFollowed ?? false, today: req.watches.today(),
                                           defaultService: try await req.watches.lastService(userID: userID, titleID: title.requireID()),
                                           watchLater: onList, availability: try await availabilityView(req, title: title, onList: onList)))
        }
    }

    /// Serves `POST /tv/:tmdbID/episodes/:season/:number/watch`: records a watch of the episode (see
    /// ``WatchService/markEpisode(userID:episodeID:day:service:rewatch:)``) and returns the updated season fragment.
    /// - Parameter req: The request with a ``WatchInput`` body.
    /// - Returns: The season section plus the out-of-band service refresh.
    /// - Throws: `Abort(.notFound)` for an unknown episode, `Abort(.badRequest)` for an unknown service,
    ///   `TrackingError.invalidDate`, `.futureDate` or `.notAired`.
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

    /// Deletes one viewing from the episode's details; the episode stays expanded.
    ///
    /// Serves `DELETE /tv/:tmdbID/episodes/:season/:number/watches/:watchID` and returns the updated season fragment.
    /// - Parameter req: The request.
    /// - Returns: The season section plus the out-of-band service refresh.
    /// - Throws: `Abort(.notFound)` for an unknown episode or malformed watch ID, `TrackingError.notFound` for a watch
    ///   of another user, title or episode.
    func deleteEpisodeWatch(req: Request) async throws -> Response {
        try await handle(req) {
            let (title, episode) = try await resolveEpisode(req)
            guard let watchID = req.parameters.get("watchID", as: UUID.self) else { throw Abort(.notFound) }
            let userID = try req.userID
            try await req.watches.deleteWatch(userID: userID, watchID: watchID, titleID: title.requireID(),
                                              episodeID: episode.requireID())
            return try await seasonResponse(req, title: title, season: episode.season, userID: userID, openEpisode: episode.number)
        }
    }

    /// Serves `POST /tv/:tmdbID/seasons/:season/watch`: „Ganze Staffel gesehen“ (whole season watched), or a new round
    /// with `rewatch=true` (see ``WatchService/markSeason(userID:titleID:season:service:rewatch:)``).
    /// - Parameter req: The request with a ``WatchInput`` body.
    /// - Returns: The season section plus the out-of-band service refresh.
    /// - Throws: `Abort(.notFound)` for a malformed season or a season without episodes, `Abort(.badRequest)` for an
    ///   unknown service.
    func markSeason(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            guard let season = req.parameters.get("season", as: Int.self) else { throw Abort(.notFound) }
            let userID = try req.userID
            let input = (try? req.content.decode(WatchInput.self)) ?? WatchInput()
            let service = try await serviceChoice(req, input.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markSeason(userID: userID, titleID: title.requireID(), season: season, service: service,
                                                 rewatch: input.rewatch == "true")
            return try await seasonResponse(req, title: title, season: season, userID: userID)
        }
    }

    /// Serves `POST /tv/:tmdbID/watch-all`: „Gesamte Serie gesehen“ (whole series watched), or a new round with
    /// `rewatch=true`, and returns all seasons.
    /// - Parameter req: The request with a ``WatchInput`` body.
    /// - Returns: The seasons list plus the out-of-band service refresh.
    /// - Throws: `Abort(.badRequest)` for an unknown service, TMDB errors when the series cannot be loaded.
    func markSeries(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            let userID = try req.userID
            let input = (try? req.content.decode(WatchInput.self)) ?? WatchInput()
            let service = try await serviceChoice(req, input.service, userID: userID, titleID: title.requireID())
            _ = try await req.watches.markSeries(userID: userID, titleID: title.requireID(), service: service, rewatch: input.rewatch == "true")
            let seasons = try await seasonModels(req, title: title, userID: userID, open: nil)
            return try await seasonsResponse(req, title: title, seasons: seasons, userID: userID)
        }
    }

    /// Serves `POST /tv/:tmdbID/episodes/:season/:number/watch-up-to`: „bis hier gesehen“ (watched up to here), undated;
    /// returns all seasons with the episode's season and details open.
    /// - Parameter req: The request; only the `service` of its ``WatchInput`` body is used.
    /// - Returns: The seasons list plus the out-of-band service refresh.
    /// - Throws: `Abort(.notFound)` for an unknown episode, `Abort(.badRequest)` for an unknown service.
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

    /// Serves `POST /tv/:tmdbID/hidden`: „Ausblenden“ / „Einblenden“ (hide / show) a series.
    ///
    /// Showing a series again refreshes it from TMDB (failures only log). From a „Weiterschauen“ card the response is
    /// empty so the card disappears; otherwise it is the updated ``HiddenToggle``.
    /// - Parameter req: The request with a ``HiddenInput`` body.
    /// - Returns: The toggle fragment or an empty fragment.
    /// - Throws: A decoding error for a missing `hidden` field, TMDB errors when the series cannot be loaded.
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

    /// Serves `GET /movie/:tmdbID`: refreshes stale TMDB data (failures only log) and renders the full movie page with
    /// the user's watches, rating, comment and the availability block.
    /// - Parameter req: The request.
    /// - Returns: The full movie page.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors when the movie cannot be loaded.
    func moviePage(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .movie)
            await refreshForDetails(req, title)
            let userID = try req.userID
            let entry = try await findEntry(req, userID: userID, titleID: title.requireID())
            let onList = try await req.watchLater.contains(userID: userID, titleID: title.requireID())
            return HTMLResponse(MoviePage(nav: try req.nav(.search), title: title,
                                          watches: try await movieWatches(req, userID: userID, titleID: title.requireID()),
                                          rating: entry?.rating, comment: entry?.comment, today: req.watches.today(),
                                          watchLater: onList, availability: try await availabilityView(req, title: title, onList: onList)))
        }
    }

    /// Serves `POST /movie/:tmdbID/watch`: records a watch of the movie (see
    /// ``WatchService/markMovie(userID:titleID:day:service:rewatch:)``) and returns the updated watches section.
    /// - Parameter req: The request with a ``WatchInput`` body.
    /// - Returns: The ``MovieWatchesSection`` fragment.
    /// - Throws: `Abort(.badRequest)` for an unknown service, `TrackingError.invalidDate` or `.futureDate`.
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

    /// Deletes one viewing from the movie page.
    ///
    /// Serves `DELETE /movie/:tmdbID/watches/:watchID` and returns the updated watches section.
    /// - Parameter req: The request.
    /// - Returns: The ``MovieWatchesSection`` fragment.
    /// - Throws: `Abort(.notFound)` for a malformed watch ID, `TrackingError.notFound` for a watch of another user or
    ///   title.
    func deleteMovieWatch(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .movie)
            guard let watchID = req.parameters.get("watchID", as: UUID.self) else { throw Abort(.notFound) }
            let userID = try req.userID
            try await req.watches.deleteWatch(userID: userID, watchID: watchID, titleID: title.requireID(), episodeID: nil)
            return HTMLResponse(MovieWatchesSection(tmdbID: title.tmdbID, watches: try await movieWatches(req, userID: userID, titleID: title.requireID()),
                                                    today: req.watches.today()))
        }
    }

    // MARK: Rating

    /// Serves `POST /tv/:tmdbID/rating` and `POST /movie/:tmdbID/rating`: sets or removes the user's rating.
    /// - Parameters:
    ///   - req: The request with a ``RatingInput`` body.
    ///   - kind: Series or movie, from the route.
    /// - Returns: The updated ``RatingControl`` fragment.
    /// - Throws: `TrackingError.invalidRating` for a non-number or a value outside 1…10.
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

    /// Serves `POST /tv/:tmdbID/follow`: „Beobachten“ / „Nicht mehr beobachten“ (follow / unfollow).
    /// - Parameter req: The request with a ``FollowInput`` body.
    /// - Returns: The updated ``FollowToggle``, or an empty fragment from the account page so the row disappears.
    /// - Throws: A decoding error for a missing `followed` field, TMDB errors when the series cannot be loaded.
    func setFollowed(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            let input = try req.content.decode(FollowInput.self)
            try await req.watches.setFollowed(userID: try req.userID, titleID: title.requireID(), followed: input.followed)
            if input.context == "account" { return HTMLResponse(EmptyHTML()) }   // row in the account list disappears
            return HTMLResponse(FollowToggle(tmdbID: title.tmdbID, followed: input.followed))
        }
    }

    /// Serves `POST /tv/:tmdbID/new-episodes/dismiss`: „Erledigt“ (done) on the „Neue Folgen“ note; returns an empty
    /// fragment so the note disappears.
    /// - Parameter req: The request.
    /// - Returns: An empty fragment.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors when the series cannot be loaded.
    func dismissNewEpisodes(req: Request) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, .tv)
            try await req.watches.dismissNewEpisodes(userID: try req.userID, titleID: title.requireID())
            return HTMLResponse(EmptyHTML())
        }
    }

    // MARK: Comments

    /// Serves `POST /tv/:tmdbID/comment` and `POST /movie/:tmdbID/comment`: saves the private title comment.
    /// - Parameters:
    ///   - req: The request with a ``CommentInput`` body.
    ///   - kind: Series or movie, from the route.
    /// - Returns: The ``CommentBox`` fragment with the saved comment.
    /// - Throws: `TrackingError.commentTooLong`.
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

    /// Serves `POST /tv/:tmdbID/seasons/:season/comment`: saves the private season comment.
    /// - Parameter req: The request with a ``CommentInput`` body.
    /// - Returns: The ``CommentBox`` fragment with the saved comment.
    /// - Throws: `Abort(.notFound)` for a malformed season, `TrackingError.commentTooLong`.
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

    /// Refreshes a title before showing its page; see ``SeriesDetailService/refreshForDetails(_:)``.
    /// - Parameters:
    ///   - req: The request.
    ///   - title: The title.
    private func refreshForDetails(_ req: Request, _ title: Title) async {
        await req.seriesDetails.refreshForDetails(title)
    }

    // MARK: Später ansehen / Verfügbarkeit

    /// Serves `POST /tv/:tmdbID/watch-later` and `POST /movie/:tmdbID/watch-later`: puts the title on or takes it off the
    /// „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - req: The request with a ``WatchLaterInput`` body.
    ///   - kind: Series or movie, from the route.
    /// - Returns: The updated ``WatchLaterToggle`` fragment.
    /// - Throws: A decoding error for a missing `watchLater` field, errors of ``WatchLaterService``.
    func setWatchLater(req: Request, kind: TitleKind) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, kind)
            let input = try req.content.decode(WatchLaterInput.self)
            let userID = try req.userID
            if input.watchLater {
                try await req.watchLater.add(userID: userID, title: title, tmdb: req.tmdb, today: req.watches.today(), logger: req.logger)
            } else {
                try await req.watchLater.remove(userID: userID, titleID: title.requireID())
            }
            return HTMLResponse(WatchLaterToggle(kind: kind, tmdbID: title.tmdbID, onList: input.watchLater))
        }
    }

    /// The block, fetched first when the stored state is missing or older than 7 days (htmx after the page load).
    ///
    /// Serves `GET /tv/:tmdbID/availability` and `GET /movie/:tmdbID/availability` (htmx): the streaming availability
    /// block. A TMDB failure is shown in the block instead of failing the request.
    /// - Parameters:
    ///   - req: The request.
    ///   - kind: Series or movie, from the route.
    /// - Returns: The ``AvailabilityBlock`` fragment.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors when the title cannot be loaded, database errors.
    func availability(req: Request, kind: TitleKind) async throws -> Response {
        try await handle(req) {
            let title = try await resolve(req, kind)
            let user = try req.currentUser
            let titleID = try title.requireID()
            var fetchError: String?
            if req.tmdbToken != nil, try await req.availability.needsRefresh(titleID: titleID, region: user.region) {
                do {
                    try await req.availability.refresh(title, tmdb: req.tmdb)
                    try await AvailabilityNoticeService(db: req.db).reconcile(titleID: titleID)
                } catch let error as TMDBError {
                    fetchError = "Abfrage bei TMDB fehlgeschlagen: \(error)"
                }
            }
            let onList = try await req.watchLater.contains(userID: try req.userID, titleID: titleID)
            var view = try await availabilityView(req, title: title, onList: onList)
            view.loading = false
            view.fetchError = fetchError
            return HTMLResponse(AvailabilityBlock(view: view))
        }
    }

    /// Builds the availability block's view model from the stored snapshot for the user's region; it shows a loading
    /// state when the user has a TMDB token and the snapshot is stale.
    /// - Parameters:
    ///   - req: The request.
    ///   - title: The title.
    ///   - onList: Whether the title is on the user's „Später ansehen“ list.
    /// - Returns: The view model.
    /// - Throws: Database errors.
    private func availabilityView(_ req: Request, title: Title, onList: Bool) async throws -> AvailabilityView {
        let user = try req.currentUser
        let titleID = try title.requireID()
        let hasToken = req.tmdbToken != nil
        let services = try await AvailabilityNoticeService(db: req.db).serviceIDs(userID: try req.userID)
        let stale = try await req.availability.needsRefresh(titleID: titleID, region: user.region)
        return AvailabilityView(kind: title.titleKind, tmdbID: title.tmdbID, titleName: title.name, region: user.region,
                                snapshot: try await req.availability.snapshot(titleID: titleID, region: user.region),
                                services: services, onList: onList, hasToken: hasToken,
                                loading: hasToken && stale)
    }

    /// Runs a route body; see ``respondMappingTrackingErrors(_:_:)``.
    /// - Parameters:
    ///   - req: The request.
    ///   - body: Builds the page or fragment.
    /// - Returns: The encoded response.
    /// - Throws: Whatever `body` throws.
    private func handle(_ req: Request, _ body: () async throws -> HTMLResponse) async throws -> Response {
        try await respondMappingTrackingErrors(req, body)
    }

    /// Loads the title named by the `tmdbID` route parameter, fetching it from TMDB when not cached.
    /// - Parameters:
    ///   - req: The request.
    ///   - kind: Series or movie.
    /// - Returns: The title.
    /// - Throws: `Abort(.notFound)` for a malformed `tmdbID`, TMDB errors from ``CatalogService/title(kind:tmdbID:)``.
    private func resolve(_ req: Request, _ kind: TitleKind) async throws -> Title {
        guard let tmdbID = req.parameters.get("tmdbID", as: Int.self) else { throw Abort(.notFound) }
        return try await req.catalog.title(kind: kind, tmdbID: tmdbID)
    }

    /// Loads the series and the episode named by the `season` and `number` route parameters.
    /// - Parameter req: The request.
    /// - Returns: The series and the episode.
    /// - Throws: `Abort(.notFound)` for malformed parameters or an unknown episode.
    private func resolveEpisode(_ req: Request) async throws -> (Title, Episode) {
        let title = try await resolve(req, .tv)
        guard let season = req.parameters.get("season", as: Int.self), let number = req.parameters.get("number", as: Int.self),
              let episode = try await Episode.query(on: req.db).filter(\.$title.$id == title.requireID())
                .filter(\.$season == season).filter(\.$number == number).first() else { throw Abort(.notFound) }
        return (title, episode)
    }

    /// Absent field → last used service of this title; "" → unknown; otherwise must be a known service.
    /// - Parameters:
    ///   - req: The request.
    ///   - raw: The submitted `service` field.
    ///   - userID: The user.
    ///   - titleID: The title.
    /// - Returns: The service to record, or nil for unknown.
    /// - Throws: `Abort(.badRequest)` for an unknown service.
    private func serviceChoice(_ req: Request, _ raw: String?, userID: UUID, titleID: UUID) async throws -> StreamingService? {
        guard let raw else { return try await req.watches.lastService(userID: userID, titleID: titleID) }
        if raw.isEmpty { return nil }
        guard let service = StreamingService(rawValue: raw) else { throw Abort(.badRequest, reason: "Unbekannter Dienst") }
        return service
    }

    /// The user's library entry for a title, if any.
    /// - Parameters:
    ///   - req: The request.
    ///   - userID: The user.
    ///   - titleID: The title.
    /// - Returns: The entry, or nil.
    /// - Throws: Database errors.
    private func findEntry(_ req: Request, userID: UUID, titleID: UUID) async throws -> UserTitle? {
        try await req.seriesDetails.entry(userID: userID, titleID: titleID)
    }

    /// The user's watches of a movie, newest first.
    /// - Parameters:
    ///   - req: The request.
    ///   - userID: The user.
    ///   - titleID: The movie.
    /// - Returns: The watches.
    /// - Throws: Database errors.
    private func movieWatches(_ req: Request, userID: UUID, titleID: UUID) async throws -> [Watch] {
        try await req.seriesDetails.movieWatches(userID: userID, titleID: titleID)
    }

    /// Renders one season section (open) after a change, plus the out-of-band refresh of the other forms' service choice.
    /// - Parameters:
    ///   - req: The request.
    ///   - title: The series.
    ///   - season: The changed season.
    ///   - userID: The user.
    ///   - openEpisode: The episode whose details stay expanded, if any.
    /// - Returns: The ``SeasonUpdate`` fragment.
    /// - Throws: `Abort(.notFound)` when the series has no such season.
    private func seasonResponse(_ req: Request, title: Title, season: Int, userID: UUID,
                                openEpisode: Int? = nil) async throws -> HTMLResponse {
        let seasons = try await seasonModels(req, title: title, userID: userID, open: season)
        guard var model = seasons.first(where: { $0.number == season }) else { throw Abort(.notFound) }
        model.openEpisode = openEpisode
        let service = try await req.watches.lastService(userID: userID, titleID: title.requireID())
        return HTMLResponse(SeasonUpdate(
            section: SeasonSection(tmdbID: title.tmdbID, season: model, today: req.watches.today(), defaultService: service),
            refresh: BulkServiceRefresh(tmdbID: title.tmdbID, selected: service, seriesRewatch: SeasonModel.seriesFullyWatched(seasons),
                                        seasons: seasons.map(\.number).filter { $0 != season })))
    }

    /// All seasons swapped, plus the series form's service choice (it sits outside `#seasons`).
    /// - Parameters:
    ///   - req: The request.
    ///   - title: The series.
    ///   - seasons: The season models to render.
    ///   - userID: The user.
    /// - Returns: The ``SeasonUpdate`` fragment.
    /// - Throws: Database errors.
    private func seasonsResponse(_ req: Request, title: Title, seasons: [SeasonModel], userID: UUID) async throws -> HTMLResponse {
        let service = try await req.watches.lastService(userID: userID, titleID: title.requireID())
        return HTMLResponse(SeasonUpdate(
            section: SeasonsList(tmdbID: title.tmdbID, seasons: seasons, today: req.watches.today(), defaultService: service),
            refresh: BulkServiceRefresh(tmdbID: title.tmdbID, selected: service, seriesRewatch: SeasonModel.seriesFullyWatched(seasons),
                                        seasons: [])))
    }

    /// The season view models; see ``SeriesDetailService/seasons(title:userID:open:)``.
    /// - Parameters:
    ///   - req: The request.
    ///   - title: The series.
    ///   - userID: The user.
    ///   - open: The season to show open, or nil for the default.
    /// - Returns: The season view models.
    /// - Throws: Database errors.
    func seasonModels(_ req: Request, title: Title, userID: UUID, open: Int?) async throws -> [SeasonModel] {
        try await req.seriesDetails.seasons(title: title, userID: userID, open: open)
    }
}
