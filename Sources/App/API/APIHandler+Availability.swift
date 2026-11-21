import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

/// „Später ansehen“, availability and streaming services (spec `2026-11-21-watch-later-availability-design.md` §7).
extension APIHandler {
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

    func setSeriesWatchLater(_ input: Operations.setSeriesWatchLater.Input) async throws -> Operations.setSeriesWatchLater.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await setWatchLater(kind: .tv, tmdbID: input.path.tmdbID, on: body.watchLater)
        return .noContent(.init())
    }

    func setMovieWatchLater(_ input: Operations.setMovieWatchLater.Input) async throws -> Operations.setMovieWatchLater.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await setWatchLater(kind: .movie, tmdbID: input.path.tmdbID, on: body.watchLater)
        return .noContent(.init())
    }

    func getSeriesAvailability(_ input: Operations.getSeriesAvailability.Input) async throws -> Operations.getSeriesAvailability.Output {
        .ok(.init(body: .json(try await availability(kind: .tv, tmdbID: input.path.tmdbID))))
    }

    func getMovieAvailability(_ input: Operations.getMovieAvailability.Input) async throws -> Operations.getMovieAvailability.Output {
        .ok(.init(body: .json(try await availability(kind: .movie, tmdbID: input.path.tmdbID))))
    }

    func getStreamingServices(_ input: Operations.getStreamingServices.Input) async throws -> Operations.getStreamingServices.Output {
        let user = try APIContext.requireUser()
        let settings = try await APIContext.request().streamingSettings.settings(user: user)
        return .ok(.init(body: .json(.init(region: settings.region, providerIds: settings.providerIDs.sorted()))))
    }

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

    func getStreamingRegions(_ input: Operations.getStreamingRegions.Input) async throws -> Operations.getStreamingRegions.Output {
        _ = try APIContext.requireUser()
        let request = try APIContext.request()
        let regions = try await request.application.providerCatalog.regions(tmdb: request.tmdb)
        return .ok(.init(body: .json(regions.map { .init(code: $0.code, name: $0.name) })))
    }

    // MARK: Helpers

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
    private func availability(kind: TitleKind, tmdbID: Int) async throws -> Components.Schemas.Availability {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let title = try await request.catalog.title(kind: kind, tmdbID: tmdbID)
        let titleID = try title.requireID()
        if try await request.availability.needsRefresh(titleID: titleID, region: user.region) {
            if request.tmdbToken != nil {
                try await request.availability.refresh(title, tmdb: request.tmdb)
                try await AvailabilityNoticeService(db: request.db).reconcile(titleID: titleID)
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

    static func availability(_ snapshot: AvailabilitySnapshot, region: String, services: Set<Int>) -> Components.Schemas.Availability {
        .init(region: region, fetchedAt: snapshot.fetchedAt, offers: snapshot.offers.map { offer in
            .init(providerId: offer.providerID, name: offer.name, logoPath: offer.logoPath,
                  kind: Components.Schemas.OfferKind(rawValue: offer.kind.rawValue) ?? .flatrate,
                  mine: services.contains(offer.providerID))
        })
    }
}
