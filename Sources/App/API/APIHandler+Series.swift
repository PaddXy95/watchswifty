import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    // MARK: Operations

    /// Handles `GET /api/v1/tv/{tmdbID}`: the series' detail, refreshed first when stale or incomplete
    /// (`SeriesDetailService.refreshForDetails`, failures are only logged).
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.ok` with the series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB.
    func getSeries(_ input: Operations.getSeries.Input) async throws -> Operations.getSeries.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        await request.seriesDetails.refreshForDetails(title)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/episodes/{season}/{number}/watch`: records a watch of one episode via
    /// `WatchService.markEpisode`.
    ///
    /// The optional body sets day, service (absent: the title's last used service, `unknown`: none) and `rewatch`.
    /// - Parameter input: The generated operation input (path `tmdbID`, `season`, `number`, optional `WatchInput`
    ///   body).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `APIError.notFound` for an unknown episode,
    ///   `TrackingError.notAired` and date errors.
    func markEpisode(_ input: Operations.markEpisode.Input) async throws -> Operations.markEpisode.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        let body = Self.watchInput(input.body)
        let service = try await Self.service(request, body?.service, user: user, title: title)
        _ = try await request.watches.markEpisode(userID: user.requireID(), episodeID: episode.requireID(), day: body?.day,
                                                  service: service, rewatch: body?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `DELETE /api/v1/tv/{tmdbID}/episodes/{season}/{number}/watch`: deletes the user's watches of the episode
    /// via `WatchService.unmarkEpisode`.
    /// - Parameter input: The generated operation input (path `tmdbID`, `season`, `number`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `APIError.notFound` for an unknown episode.
    func unmarkEpisode(_ input: Operations.unmarkEpisode.Input) async throws -> Operations.unmarkEpisode.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        try await request.watches.unmarkEpisode(userID: user.requireID(), episodeID: episode.requireID())
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/episodes/{season}/{number}/watch-up-to`: marks this episode and all earlier
    /// aired, unwatched ones undated via `WatchService.markUpTo` (for a special: the earlier specials; otherwise
    /// regular episodes only).
    /// - Parameter input: The generated operation input (path `tmdbID`, `season`, `number`, optional `WatchInput` body
    ///   for the service).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `APIError.notFound` for an unknown episode.
    func markUpTo(_ input: Operations.markUpTo.Input) async throws -> Operations.markUpTo.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let episode = try await Self.episode(request, title: title, season: input.path.season, number: input.path.number)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markUpTo(userID: user.requireID(), episodeID: episode.requireID(), service: service)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/seasons/{season}/watch`: „Ganze Staffel gesehen“ (whole season watched) via
    /// `WatchService.markSeason`; with `rewatch` a new round.
    /// - Parameter input: The generated operation input (path `tmdbID`, `season`, optional `WatchInput` body).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, errors of `WatchService.markSeason`.
    func markSeason(_ input: Operations.markSeason.Input) async throws -> Operations.markSeason.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markSeason(userID: user.requireID(), titleID: title.requireID(), season: input.path.season,
                                                 service: service, rewatch: Self.watchInput(input.body)?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `POST /api/v1/tv/{tmdbID}/watch-all`: „Gesamte Serie gesehen“ (whole series watched) via
    /// `WatchService.markSeries`; with `rewatch` a new round.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional `WatchInput` body).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, errors of `WatchService.markSeries`.
    func markSeries(_ input: Operations.markSeries.Input) async throws -> Operations.markSeries.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let service = try await Self.service(request, Self.watchInput(input.body)?.service, user: user, title: title)
        _ = try await request.watches.markSeries(userID: user.requireID(), titleID: title.requireID(), service: service,
                                                 rewatch: Self.watchInput(input.body)?.rewatch ?? false)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/hidden`: hides or shows the series via `WatchService.setHidden`; showing it
    /// again refreshes it from TMDB (failures are only logged).
    /// - Parameter input: The generated operation input (path `tmdbID`, JSON body with `hidden`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `TMDBError` when the series is neither cached for this user nor loadable from TMDB.
    func setHidden(_ input: Operations.setHidden.Input) async throws -> Operations.setHidden.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.watches.setHidden(userID: user.requireID(), titleID: title.requireID(), hidden: body.hidden)
        if !body.hidden {
            do { try await request.catalog.refresh(title) } catch {
                request.logger.warning("TMDB refresh after unhide failed for \(title.tmdbID): \(error)")
            }
        }
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/follow`: follows or unfollows the series via `WatchService.setFollowed`.
    /// - Parameter input: The generated operation input (path `tmdbID`, JSON body with `followed`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `TMDBError` when the series is neither cached for this user nor loadable from TMDB.
    func setFollowed(_ input: Operations.setFollowed.Input) async throws -> Operations.setFollowed.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.watches.setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: body.followed)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/rating`: sets or (without a rating) clears the user's rating via
    /// `WatchService.setRating`.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional body with `rating`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `TrackingError.invalidRating`.
    func setSeriesRating(_ input: Operations.setSeriesRating.Input) async throws -> Operations.setSeriesRating.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let rating: Int? = if case let .json(body)? = input.body { body.rating } else { nil }
        try await request.watches.setRating(userID: user.requireID(), titleID: title.requireID(), rating: rating)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/comment`: sets or clears the user's comment via `WatchService.setComment`.
    /// - Parameter input: The generated operation input (path `tmdbID`, optional body with `comment`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `TrackingError.commentTooLong`.
    func setSeriesComment(_ input: Operations.setSeriesComment.Input) async throws -> Operations.setSeriesComment.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setComment(userID: user.requireID(), titleID: title.requireID(), comment: comment)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/seasons/{season}/comment`: sets or clears the user's comment on a season via
    /// `WatchService.setSeasonComment`.
    /// - Parameter input: The generated operation input (path `tmdbID`, `season`, optional body with `comment`).
    /// - Returns: `.ok` with the updated series detail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB, `TrackingError.commentTooLong`.
    func setSeasonComment(_ input: Operations.setSeasonComment.Input) async throws -> Operations.setSeasonComment.Output {
        let (request, user, title) = try await seriesContext(input.path.tmdbID)
        let comment: String? = if case let .json(body)? = input.body { body.comment } else { nil }
        try await request.watches.setSeasonComment(userID: user.requireID(), titleID: title.requireID(), season: input.path.season,
                                                   comment: comment)
        return .ok(.init(body: .json(try await Self.seriesDetail(request, user: user, title: title))))
    }

    // MARK: Helpers

    /// Request, signed-in user and the series (cached or fetched with the user's TMDB token).
    /// - Parameter tmdbID: The series' TMDB ID.
    /// - Returns: The request, the user and the title.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   series is neither cached for this user nor loadable from TMDB.
    private func seriesContext(_ tmdbID: Int) async throws -> (Request, User, Title) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        return (request, user, try await request.catalog.title(kind: .tv, tmdbID: tmdbID))
    }

    /// Finds an episode of the series by season and number.
    /// - Parameters:
    ///   - request: The current request.
    ///   - title: The series.
    ///   - season: The season number.
    ///   - number: The episode number.
    /// - Returns: The episode.
    /// - Throws: `APIError.notFound` for an unknown episode, database errors.
    static func episode(_ request: Request, title: Title, season: Int, number: Int) async throws -> Episode {
        guard let episode = try await Episode.query(on: request.db).filter(\.$title.$id == title.requireID())
            .filter(\.$season == season).filter(\.$number == number).first() else { throw APIError.notFound }
        return episode
    }

    /// Extracts the optional `WatchInput` JSON body of the four marking operations.
    /// - Parameter body: The operation's body.
    /// - Returns: The input, or nil without a body or for other operations.
    static func watchInput<Body>(_ body: Body?) -> Components.Schemas.WatchInput? {
        switch body {
        case let body as Operations.markEpisode.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markUpTo.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markSeason.Input.Body: if case let .json(value) = body { return value }
        case let body as Operations.markSeries.Input.Body: if case let .json(value) = body { return value }
        default: break
        }
        return nil
    }

    /// Absent → last used service of this title; `unknown` → none; otherwise that service.
    /// - Parameters:
    ///   - request: The current request.
    ///   - choice: The service from the body, if any.
    ///   - user: The signed-in user.
    ///   - title: The watched title.
    /// - Returns: The service to record, or nil.
    /// - Throws: Database errors.
    static func service(_ request: Request, _ choice: Components.Schemas.WatchInput.servicePayload?, user: User,
                        title: Title) async throws -> StreamingService? {
        guard let choice else { return try await request.watches.lastService(userID: user.requireID(), titleID: title.requireID()) }
        return choice == .unknown ? nil : StreamingService(rawValue: choice.rawValue)
    }

    /// Builds the `SeriesDetail` schema with the user's state, the next episode and every season with its episodes.
    /// - Parameters:
    ///   - request: The current request.
    ///   - user: The signed-in user.
    ///   - title: The series.
    /// - Returns: The schema value.
    /// - Throws: Database errors.
    static func seriesDetail(_ request: Request, user: User, title: Title) async throws -> Components.Schemas.SeriesDetail {
        let model = try await request.seriesDetails.detail(userID: user.requireID(), title: title)
        // Same rule as „Weiterschauen“: the first aired, unwatched regular episode after the highest one watched in the
        // current round.
        let rows = model.seasons.flatMap(\.episodes)
        let today = request.watches.today()
        let counts = Dictionary(uniqueKeysWithValues: rows.map { ($0.info.id, $0.watches.count) })
        let round = currentRound(in: rows.map(\.info), watchCounts: counts, today: today)
        let next = App.nextEpisode(in: rows.map(\.info), watched: round, today: today)
        return .init(
            tmdbId: title.tmdbID, name: title.name, year: title.year, posterPath: title.posterPath,
            overview: title.overview.flatMap { $0.isEmpty ? nil : $0 }, status: title.tmdbStatus,
            runtime: title.runtime.flatMap { $0 > 0 ? $0 : nil }, genres: genres(title), links: links(title),
            rating: model.rating, comment: model.comment, hidden: model.hidden, followed: model.followed,
            watchLater: try await request.watchLater.contains(userID: user.requireID(), titleID: title.requireID()),
            lastService: model.defaultService.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) },
            next: next.map { .init(episodeId: $0.id.uuidString, season: $0.season, number: $0.number, name: $0.name, airDate: $0.airDate) },
            seasons: model.seasons.map { season in
                .init(number: season.number, title: season.title, watchedCount: season.watchedCount, comment: season.comment,
                      isOpen: season.isOpen, episodes: season.episodes.map { row in
                          .init(season: row.info.season, number: row.info.number, name: row.info.name, airDate: row.info.airDate,
                                overview: row.info.overview.flatMap { $0.isEmpty ? nil : $0 },
                                runtime: row.info.runtime.flatMap { $0 > 0 ? $0 : nil }, aired: row.aired,
                                watches: row.watches.map(watchSummary))
                      })
            })
    }

    /// The title's external links (TMDB, IMDb, Rotten Tomatoes, SeriesGraph); missing ones are empty or nil.
    /// - Parameter title: The title.
    /// - Returns: The schema value.
    static func links(_ title: Title) -> Components.Schemas.Links {
        let all = Dictionary(externalLinks(for: title).map { ($0.label, $0.url) }, uniquingKeysWith: { a, _ in a })
        return .init(tmdb: all["TMDB"] ?? "", imdb: all["IMDb"] ?? "", rottenTomatoes: all["Rotten Tomatoes"] ?? "",
                     seriesGraph: all["SeriesGraph"])
    }

    /// Maps a watch to the `WatchSummary` schema.
    /// - Parameter watch: The watch.
    /// - Returns: The schema value.
    static func watchSummary(_ watch: Watch) -> Components.Schemas.WatchSummary {
        .init(id: watch.id?.uuidString ?? "", day: watch.watchedOn,
              service: watch.service.flatMap { Components.Schemas.Service(rawValue: $0) },
              origin: watch.watchOrigin == .import ? ._import : .manual)
    }
}
