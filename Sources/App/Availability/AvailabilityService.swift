import Fluent
import Foundation
import Vapor

/// One stored offer of a title in the user's country.
struct Offer: Sendable, Equatable {
    /// TMDB provider id of the service.
    let providerID: Int
    /// Name of the service.
    let name: String
    let logoPath: String?
    let kind: OfferKind
    let displayPriority: Int

    /// Creates an offer.
    /// - Parameters:
    ///   - providerID: TMDB provider id of the service.
    ///   - name: Name of the service.
    ///   - logoPath: TMDB image path of the service's logo.
    ///   - kind: Subscription, free, ads, rent or buy.
    ///   - displayPriority: TMDB's display priority (lower comes first).
    init(providerID: Int, name: String, logoPath: String?, kind: OfferKind, displayPriority: Int) {
        self.providerID = providerID
        self.name = name
        self.logoPath = logoPath
        self.kind = kind
        self.displayPriority = displayPriority
    }

    /// Creates an offer from a TMDB offer.
    /// - Parameter offer: The offer as returned by TMDB.
    init(_ offer: TMDBOffer) {
        self.init(providerID: offer.providerID, name: offer.name, logoPath: offer.logoPath, kind: offer.kind,
                  displayPriority: offer.displayPriority)
    }
}

/// A title's stored offers in one country; `offers` sorted by display priority, then name.
struct AvailabilitySnapshot: Sendable, Equatable {
    /// When the offers were fetched.
    let fetchedAt: Date
    let offers: [Offer]
}

/// The offers as the detail page and the list show them (spec §5).
struct AvailabilityGroups: Sendable, Equatable {
    /// Whether the user has selected any streaming services.
    let hasServices: Bool
    /// Subscription offers at the user's services („In deinen Abos“).
    let mine: [Offer]
    /// Other subscription offers („Weitere Abos“; all of them when the user has no services: „Im Abo“).
    let otherSubscriptions: [Offer]
    /// Free and ad-supported offers.
    let free: [Offer]
    /// Rent and buy offers, one per provider and kind.
    let rentOrBuy: [Offer]

    /// Groups a snapshot's offers for display.
    /// - Parameters:
    ///   - snapshot: The stored offers in the user's country.
    ///   - services: The user's services (TMDB provider ids).
    init(snapshot: AvailabilitySnapshot, services: Set<Int>) {
        hasServices = !services.isEmpty
        let subscriptions = snapshot.offers.filter { $0.kind == .flatrate }
        mine = subscriptions.filter { services.contains($0.providerID) }
        otherSubscriptions = subscriptions.filter { !services.contains($0.providerID) }
        free = snapshot.offers.filter { $0.kind == .free || $0.kind == .ads }
        var seen = Set<String>()
        rentOrBuy = snapshot.offers.filter { ($0.kind == .rent || $0.kind == .buy) && seen.insert("\($0.providerID):\($0.kind)").inserted }
    }

    /// Offers at the user's services that count for „Bei deinen Diensten“ and notifications.
    ///
    /// These are the subscription offers at the user's services plus free and ad-supported offers of those services.
    /// - Parameter services: The user's services (TMDB provider ids).
    /// - Returns: The matching offers.
    func atServices(_ services: Set<Int>) -> [Offer] {
        mine + free.filter { services.contains($0.providerID) }
    }
}

/// Fetching and storing where titles stream (TMDB watch providers, data by JustWatch; spec §4).
struct AvailabilityService {
    /// The detail page fetches again when the stored state is older.
    static let staleAfter: TimeInterval = 7 * 86_400
    /// Stored offers are deleted when not fetched for this long (spec §4.4).
    static let maxAge: TimeInterval = 30 * 86_400
    /// Offer kinds that count as „available at my service“ and can be notified.
    static let notifyKinds: Set<OfferKind> = [.flatrate, .free, .ads]

    /// The database holding the offers.
    let db: any Database

    /// Countries of all users (nil counts as `DE`), sorted.
    /// - Returns: The distinct country codes of all users.
    /// - Throws: Database errors.
    func regionsInUse() async throws -> [String] {
        let users = try await User.query(on: db).field(\.$id).field(\.$watchRegion).all()
        return Array(Set(users.map(\.region))).sorted()
    }

    /// Fetches the title's offers and replaces the stored ones (only countries in use). A TMDB error leaves the stored
    /// state unchanged.
    /// - Parameters:
    ///   - title: The title (must be cached, i.e. have an ID).
    ///   - tmdb: The TMDB client to fetch with.
    ///   - now: The fetch time stored in `title_availability`.
    /// - Throws: `TMDBError` from the fetch, Fluent's error for a title without ID, or database errors.
    func refresh(_ title: Title, tmdb: any TMDBClient, now: Date = .now) async throws {
        let fetched = try await tmdb.watchProviders(kind: title.titleKind, id: title.tmdbID)
        let regions = try await regionsInUse()
        let titleID = try title.requireID()
        try await db.transaction { db in
            try await TitleProvider.query(on: db).filter(\.$title.$id == titleID).delete()
            for region in regions {
                for offer in fetched.offers[region] ?? [] {
                    try await TitleProvider(titleID: titleID, region: region, offer: offer).create(on: db)
                }
            }
            let link = regions.lazy.compactMap { fetched.links[$0] }.first
            if let existing = try await TitleAvailability.query(on: db).filter(\.$title.$id == titleID).first() {
                existing.fetchedAt = now
                existing.regions = regions.sorted().joined(separator: ",")
                existing.tmdbLink = link
                try await existing.save(on: db)
            } else {
                try await TitleAvailability(titleID: titleID, fetchedAt: now, regions: regions, tmdbLink: link).create(on: db)
            }
        }
    }

    /// The stored offers in `region`; nil when never fetched or the fetch did not cover the country.
    /// - Parameters:
    ///   - titleID: The title.
    ///   - region: The country code.
    /// - Returns: The stored offers, sorted by display priority and name.
    /// - Throws: Database errors.
    func snapshot(titleID: UUID, region: String) async throws -> AvailabilitySnapshot? {
        try await snapshots(titleIDs: [titleID], region: region)[titleID]
    }

    /// `snapshot` for many titles at once.
    /// - Parameters:
    ///   - titleIDs: The titles.
    ///   - region: The country code.
    /// - Returns: Snapshots by title ID; titles not fetched for the country are absent.
    /// - Throws: Database errors.
    func snapshots(titleIDs: [UUID], region: String) async throws -> [UUID: AvailabilitySnapshot] {
        guard !titleIDs.isEmpty else { return [:] }
        var result: [UUID: AvailabilitySnapshot] = [:]
        for chunk in titleIDs.chunked() {
            let states = try await TitleAvailability.query(on: db).filter(\.$title.$id ~~ Array(chunk)).all()
                .filter { $0.regionList.contains(region) }
            guard !states.isEmpty else { continue }
            let rows = try await TitleProvider.query(on: db).filter(\.$title.$id ~~ states.map(\.$title.id))
                .filter(\.$region == region).all()
            let byTitle = Dictionary(grouping: rows, by: \.$title.id)
            for state in states {
                let offers = (byTitle[state.$title.id] ?? []).compactMap { row in
                    row.offerKind.map { Offer(providerID: row.providerID, name: row.providerName, logoPath: row.logoPath, kind: $0,
                                              displayPriority: row.displayPriority) }
                }.sorted { ($0.displayPriority, $0.name) < ($1.displayPriority, $1.name) }
                result[state.$title.id] = AvailabilitySnapshot(fetchedAt: state.fetchedAt, offers: offers)
            }
        }
        return result
    }

    /// Whether the detail page should fetch: nothing stored for the country, or older than `staleAfter`.
    /// - Parameters:
    ///   - titleID: The title.
    ///   - region: The user's country code.
    ///   - now: The reference time.
    /// - Returns: `true` if the detail page should fetch the offers again.
    /// - Throws: Database errors.
    func needsRefresh(titleID: UUID, region: String, now: Date = .now) async throws -> Bool {
        guard let snapshot = try await snapshot(titleID: titleID, region: region) else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) > Self.staleAfter
    }

    /// Deletes stored offers not fetched for `maxAge` (notices stay, so a long gap does not report twice).
    ///
    /// Deletes both the `title_providers` rows and the `title_availability` row of each such title.
    /// - Parameter now: The reference time.
    /// - Returns: The number of titles whose data was deleted.
    /// - Throws: Database errors.
    @discardableResult
    func expire(now: Date = .now) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let old = try await TitleAvailability.query(on: db).filter(\.$fetchedAt < cutoff).all()
        guard !old.isEmpty else { return 0 }
        let titleIDs = old.map(\.$title.id)
        for chunk in titleIDs.chunked() {
            try await TitleProvider.query(on: db).filter(\.$title.$id ~~ Array(chunk)).delete()
            try await TitleAvailability.query(on: db).filter(\.$title.$id ~~ Array(chunk)).delete()
        }
        return old.count
    }
}

extension Request {
    /// The availability service for this request.
    var availability: AvailabilityService { AvailabilityService(db: db) }
}
