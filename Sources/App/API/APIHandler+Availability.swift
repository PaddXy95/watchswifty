import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

/// „Später ansehen“, availability and streaming services (spec `2026-11-21-watch-later-availability-design.md` §7).
extension APIHandler {
    /// Handles `GET /api/v1/watch-later`: the user's „Später ansehen“ (watch later) list, newest first, with the stored
    /// availability in the user's region (nothing is fetched from TMDB here).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the region and the items.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getWatchLater(_ input: Operations.getWatchLater.Input) async throws -> Operations.getWatchLater.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let page = try await request.watchLater.page(user: user, filter: "all")
        let services = try await AvailabilityNoticeService(db: request.db).serviceIDs(userID: user.requireID())
        let snapshots = try await request.availability.snapshots(titleIDs: (page.atMyServices + page.others).compactMap(\.title.id),
                                                                 region: user.region)
        let items = (page.atMyServices + page.others).sorted { $0.addedAt > $1.addedAt }.map { item in
            Components.Schemas.WatchLaterItem(
                kind: item.title.titleKind == .tv ? .tv : .movie, tmdbId: item.title.tmdbID, name: item.title.name, year: item.title.year,
                posterPath: item.title.posterPath, addedAt: item.addedAt,
                availability: item.title.id.flatMap { snapshots[$0] }.map { Self.availability($0, region: user.region, services: services) },
                newSince: item.newSince)
        }
        return .ok(.init(body: .json(.init(region: user.region, items: items))))
    }

    /// Handles `PUT /api/v1/tv/{tmdbID}/watch-later`: adds the series to or removes it from „Später ansehen“ (watch
    /// later).
    /// - Parameter input: The generated operation input (path `tmdbID`, JSON body with `watchLater`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `TMDBError` when the series is neither cached for this user nor loadable from TMDB, errors of
    ///   `WatchLaterService`.
    func setSeriesWatchLater(_ input: Operations.setSeriesWatchLater.Input) async throws -> Operations.setSeriesWatchLater.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await setWatchLater(kind: .tv, tmdbID: input.path.tmdbID, on: body.watchLater)
        return .noContent(.init())
    }

    /// Handles `PUT /api/v1/movies/{tmdbID}/watch-later`: adds the movie to or removes it from „Später ansehen“ (watch
    /// later).
    /// - Parameter input: The generated operation input (path `tmdbID`, JSON body with `watchLater`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `TMDBError` when the movie is neither cached for this user nor loadable from TMDB, errors of
    ///   `WatchLaterService`.
    func setMovieWatchLater(_ input: Operations.setMovieWatchLater.Input) async throws -> Operations.setMovieWatchLater.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await setWatchLater(kind: .movie, tmdbID: input.path.tmdbID, on: body.watchLater)
        return .noContent(.init())
    }

    /// Handles `GET /api/v1/tv/{tmdbID}/availability`: where the series streams in the user's region.
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.ok` with the availability.
    /// - Throws: See `availability(kind:tmdbID:)`.
    func getSeriesAvailability(_ input: Operations.getSeriesAvailability.Input) async throws -> Operations.getSeriesAvailability.Output {
        .ok(.init(body: .json(try await availability(kind: .tv, tmdbID: input.path.tmdbID))))
    }

    /// Handles `GET /api/v1/movies/{tmdbID}/availability`: where the movie streams in the user's region.
    /// - Parameter input: The generated operation input (path `tmdbID`).
    /// - Returns: `.ok` with the availability.
    /// - Throws: See `availability(kind:tmdbID:)`.
    func getMovieAvailability(_ input: Operations.getMovieAvailability.Input) async throws -> Operations.getMovieAvailability.Output {
        .ok(.init(body: .json(try await availability(kind: .movie, tmdbID: input.path.tmdbID))))
    }

    /// Handles `GET /api/v1/me/streaming-services`: the user's region and chosen streaming providers.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with region and provider IDs.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getStreamingServices(_ input: Operations.getStreamingServices.Input) async throws -> Operations.getStreamingServices.Output {
        let user = try APIContext.requireUser()
        let settings = try await APIContext.request().streamingSettings.settings(user: user)
        return .ok(.init(body: .json(.init(region: settings.region, providerIds: settings.providerIDs.sorted()))))
    }

    /// Handles `PUT /api/v1/me/streaming-services`: saves region and providers via `StreamingSettingsService.save`.
    ///
    /// When the region changed and the user has a TMDB token, missing availability is fetched in the background.
    /// - Parameter input: The generated operation input (JSON body with region and provider IDs).
    /// - Returns: `.ok` with the saved region and provider IDs.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `StreamingSettingsService.save`.
    func setStreamingServices(_ input: Operations.setStreamingServices.Input) async throws -> Operations.setStreamingServices.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let changedRegion = try await request.streamingSettings.save(user: user, region: body.region, providerIDs: body.providerIds)
        if changedRegion, let token = request.tmdbToken {
            let app = request.application, userID = try user.requireID(), region = user.region
            app.backgroundTasks.run {
                await StreamingSettingsService(db: app.db).fetchMissing(userID: userID, region: region, tmdb: app.tmdbProvider.make(token),
                                                                        logger: app.logger)
            }
        }
        let settings = try await request.streamingSettings.settings(user: user)
        return .ok(.init(body: .json(.init(region: settings.region, providerIds: settings.providerIDs.sorted()))))
    }

    /// Handles `GET /api/v1/streaming-providers`: TMDB's streaming providers of a region (`ProviderCatalog`).
    /// - Parameter input: The generated operation input (query `region`, a two-letter country code).
    /// - Returns: `.ok` with the providers.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   for an invalid region, `TMDBError` from the provider list.
    func getStreamingProviders(_ input: Operations.getStreamingProviders.Input) async throws -> Operations.getStreamingProviders.Output {
        _ = try APIContext.requireUser()
        let request = try APIContext.request()
        let region = input.query.region.uppercased()
        guard region.count == 2, region.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw APIError.validation(StreamingSettingsService.regionMessage)
        }
        let providers = try await request.application.providerCatalog.providers(region: region, tmdb: request.tmdb)
        return .ok(.init(body: .json(providers.map {
            .init(providerId: $0.providerID, name: $0.name, logoPath: $0.logoPath,
                  displayPriority: $0.displayPriority == Int.max ? nil : $0.displayPriority)
        })))
    }

    /// Handles `GET /api/v1/streaming-regions`: the regions TMDB has provider data for (`ProviderCatalog`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with code and name per region.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` from the
    ///   region list.
    func getStreamingRegions(_ input: Operations.getStreamingRegions.Input) async throws -> Operations.getStreamingRegions.Output {
        _ = try APIContext.requireUser()
        let request = try APIContext.request()
        let regions = try await request.application.providerCatalog.regions(tmdb: request.tmdb)
        return .ok(.init(body: .json(regions.map { .init(code: $0.code, name: $0.name) })))
    }

    // MARK: Helpers

    /// Adds a title to (`WatchLaterService.add`) or removes it from the user's „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - kind: Series or movie.
    ///   - tmdbID: The title's TMDB ID.
    ///   - on: Whether the title should be on the list.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `TMDBError` when the
    ///   title is neither cached for this user nor loadable from TMDB, errors of `WatchLaterService`.
    private func setWatchLater(kind: TitleKind, tmdbID: Int, on: Bool) async throws {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: kind, tmdbID: tmdbID)
        if on {
            try await request.watchLater.add(userID: user.requireID(), title: title, tmdb: request.tmdb, today: request.watches.today(),
                                             logger: request.logger)
        } else {
            try await request.watchLater.remove(userID: user.requireID(), titleID: title.requireID())
        }
    }

    /// Stored offers in the user's country, fetched first when missing or older than 7 days. Without a token the stored
    /// state is returned; with nothing stored that is the missing-token error.
    /// - Parameters:
    ///   - kind: Series or movie.
    ///   - tmdbID: The title's TMDB ID.
    /// - Returns: The availability schema (empty offers when nothing is stored).
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token,
    ///   `TMDBError.missingToken` without a token and stored state, a `TMDBError` of the fetch when no older state
    ///   exists, `TMDBError` when the title is neither cached for this user nor loadable.
    private func availability(kind: TitleKind, tmdbID: Int) async throws -> Components.Schemas.Availability {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: kind, tmdbID: tmdbID)
        let titleID = try title.requireID()
        if try await request.availability.needsRefresh(titleID: titleID, region: user.region) {
            if request.tmdbToken != nil {
                do {
                    try await request.availability.refresh(title, tmdb: request.tmdb)
                    try await AvailabilityNoticeService(db: request.db).reconcile(titleID: titleID)
                } catch let error as TMDBError {
                    // Like the web block: an older stored state is better than an error.
                    guard try await request.availability.snapshot(titleID: titleID, region: user.region) != nil else { throw error }
                }
            } else if try await request.availability.snapshot(titleID: titleID, region: user.region) == nil {
                throw TMDBError.missingToken
            }
        }
        let services = try await AvailabilityNoticeService(db: request.db).serviceIDs(userID: user.requireID())
        guard let snapshot = try await request.availability.snapshot(titleID: titleID, region: user.region) else {
            return .init(region: user.region, offers: [])
        }
        return Self.availability(snapshot, region: user.region, services: services)
    }

    /// Maps an availability snapshot to the `Availability` schema; `mine` marks offers at the user's own services.
    /// - Parameters:
    ///   - snapshot: The stored offers.
    ///   - region: The user's region.
    ///   - services: The provider IDs of the user's services.
    /// - Returns: The schema value.
    static func availability(_ snapshot: AvailabilitySnapshot, region: String, services: Set<Int>) -> Components.Schemas.Availability {
        .init(region: region, fetchedAt: snapshot.fetchedAt, offers: snapshot.offers.map { offer in
            .init(providerId: offer.providerID, name: offer.name, logoPath: offer.logoPath,
                  kind: Components.Schemas.OfferKind(rawValue: offer.kind.rawValue) ?? .flatrate,
                  mine: services.contains(offer.providerID))
        })
    }
}
