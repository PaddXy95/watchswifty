import Fluent
import Foundation
import Vapor

/// One title on the „Später ansehen“ page.
struct WatchLaterItem: Sendable {
    let title: Title
    let addedAt: Date
    /// Offers in the user's country; nil when not fetched for it yet.
    let groups: AvailabilityGroups?
    /// Offers at the user's services (subscription, free, ads).
    let available: [Offer]
    /// Earliest appearance of a new offer at the user's services within the last 7 days („neu seit“).
    let newSince: Date?
}

/// The „Später ansehen“ page (spec §3.2).
struct WatchLaterPage: Sendable {
    let region: String
    let atMyServices: [WatchLaterItem]
    let others: [WatchLaterItem]
    let hasServices: Bool
    /// Oldest fetch among the listed titles („Stand“).
    let oldestFetch: Date?
}

/// The per-user „Später ansehen“ list (spec §3).
struct WatchLaterService {
    static let filters = ["all", "tv", "movie"]
    static let newWindow: TimeInterval = 7 * 86_400

    let db: any Database

    /// Looks the title up through `catalog` (TMDB for an uncached one, the token-less rule for cached ones) and adds it.
    @discardableResult
    func add(userID: UUID, kind: TitleKind, tmdbID: Int, catalog: CatalogService, today: String, now: Date = .now,
             logger: Logger) async throws -> Title {
        let title = try await catalog.title(kind: kind, tmdbID: tmdbID)
        try await add(userID: userID, title: title, tmdb: catalog.tmdb, today: today, now: now, logger: logger)
        return title
    }

    /// Adds the entry if missing and fetches the offers right away, so what already runs is recorded as known. A TMDB
    /// error keeps the entry; the next daily pass records the starting point.
    func add(userID: UUID, title: Title, tmdb: any TMDBClient, today: String, now: Date = .now, logger: Logger) async throws {
        let titleID = try title.requireID()
        guard try await !contains(userID: userID, titleID: titleID) else { return }
        try await WatchLaterEntry(userID: userID, titleID: titleID, addedAt: now, addedOn: today).create(on: db)
        do {
            try await AvailabilityService(db: db).refresh(title, tmdb: tmdb, now: now)
            try await AvailabilityNoticeService(db: db).reconcile(titleID: titleID, now: now)
        } catch let error as TMDBError {
            logger.info("Verfügbarkeit für „\(title.name)“ nicht abgefragt: \(error)")
        }
    }

    /// Removes the entry and the user's known offers of the title.
    func remove(userID: UUID, titleID: UUID) async throws {
        try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).delete()
        try await AvailabilityNotice.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).delete()
    }

    func contains(userID: UUID, titleID: UUID) async throws -> Bool {
        try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() != nil
    }

    /// TMDB ids of `kind` among `tmdbIDs` that are on the user's list (search results).
    func containsTMDB(userID: UUID, kind: TitleKind, tmdbIDs: [Int]) async throws -> Set<Int> {
        guard !tmdbIDs.isEmpty else { return [] }
        let titles = try await Title.query(on: db).filter(\.$kind == kind.rawValue).filter(\.$tmdbID ~~ tmdbIDs).all()
        guard !titles.isEmpty else { return [] }
        let listed = Set(try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$title.$id ~~ titles.compactMap(\.id)).all().map(\.$title.id))
        return Set(titles.filter { $0.id.map(listed.contains) ?? false }.map(\.tmdbID))
    }

    /// A new watch ends the entry: always for watches entered by hand, for imported ones only when dated on or after
    /// the day of adding – importing an old history must not empty the list (spec §3.1).
    func removeAfterWatch(userID: UUID, titleID: UUID, day: String?, origin: WatchOrigin) async throws {
        guard let entry = try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first()
        else { return }
        if origin == .import {
            guard let day, day >= entry.addedOn else { return }
        }
        try await remove(userID: userID, titleID: titleID)
    }

    /// The list, newest first, split by whether a title runs at one of the user's services.
    func page(user: User, filter rawFilter: String, now: Date = .now) async throws -> WatchLaterPage {
        let userID = try user.requireID()
        let filter = Self.filters.contains(rawFilter) ? rawFilter : "all"
        let entries = try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).sort(\.$addedAt, .descending).all()
        let titleIDs = entries.map(\.$title.id)
        var titles: [UUID: Title] = [:]
        for chunk in titleIDs.chunked() {
            for title in try await Title.query(on: db).filter(\.$id ~~ Array(chunk)).all() { titles[title.id!] = title }
        }
        let notices = AvailabilityNoticeService(db: db)
        let services = try await notices.serviceIDs(userID: userID)
        let snapshots = try await AvailabilityService(db: db).snapshots(titleIDs: titleIDs, region: user.region)
        let fresh = try await notices.newSince(userID: userID, since: now.addingTimeInterval(-Self.newWindow))
        var mine: [WatchLaterItem] = []
        var others: [WatchLaterItem] = []
        for entry in entries {
            guard let title = titles[entry.$title.id], filter == "all" || title.kind == filter else { continue }
            let snapshot = snapshots[entry.$title.id]
            let groups = snapshot.map { AvailabilityGroups(snapshot: $0, services: services) }
            let available = groups?.atServices(services) ?? []
            let atServices = !available.isEmpty
            let item = WatchLaterItem(title: title, addedAt: entry.addedAt, groups: groups, available: available,
                                      newSince: atServices ? fresh[entry.$title.id] : nil)
            if atServices { mine.append(item) } else { others.append(item) }
        }
        let shown = Set((mine + others).compactMap(\.title.id))
        let oldest = snapshots.filter { shown.contains($0.key) }.map(\.value.fetchedAt).min()
        return WatchLaterPage(region: user.region, atMyServices: mine, others: others, hasServices: !services.isEmpty, oldestFetch: oldest)
    }
}

extension Request {
    var watchLater: WatchLaterService { WatchLaterService(db: db) }
}
