import Fluent
import Foundation

/// A title on the list that became available at the user's services and waits for the digest.
struct AvailabilityDue: Sendable, Equatable {
    let titleID: UUID
    let tmdbID: Int
    let kind: TitleKind
    let name: String
    let year: Int?
    /// Service names, by display priority.
    let providers: [String]
    /// The pending notices behind this item, marked as sent after a successful send.
    let noticeIDs: [UUID]
}

/// Which offers of „Später ansehen“ titles a user already knows (spec §4.3, §6).
struct AvailabilityNoticeService {
    /// The database holding the notices.
    let db: any Database

    /// After a successful fetch of the title: per list entry whose user's country the fetch covered, records offers at
    /// the user's services as `.baseline` (entry not yet baselined) or as new (`.pending` / `.skipped`), and forgets
    /// offers that are gone, so a return is reported again.
    /// - Parameters:
    ///   - titleID: The fetched title.
    ///   - now: The time recorded on new notices.
    /// - Throws: Database errors.
    func reconcile(titleID: UUID, now: Date = .now) async throws {
        try await reconcile(entries: try await WatchLaterEntry.query(on: db).filter(\.$title.$id == titleID).all(), titleID: titleID, now: now)
    }

    /// `reconcile` for entries loaded earlier: each one is read again, so an entry removed or re-baselined meanwhile (by
    /// the user while a fetch was running) is not written with stale state. Concurrent runs may insert the same notice;
    /// the second insert is ignored.
    /// - Parameters:
    ///   - loaded: The list entries of the title, loaded before the fetch.
    ///   - titleID: The fetched title.
    ///   - now: The time recorded on new notices.
    /// - Throws: Database errors.
    func reconcile(entries loaded: [WatchLaterEntry], titleID: UUID, now: Date = .now) async throws {
        guard !loaded.isEmpty else { return }
        let availability = AvailabilityService(db: db)
        for loadedEntry in loaded {
            guard let entryID = loadedEntry.id, let entry = try await WatchLaterEntry.find(entryID, on: db),
                  let user = try await User.find(entry.$user.id, on: db),
                  let snapshot = try await availability.snapshot(titleID: titleID, region: user.region) else { continue }
            let userID = try user.requireID()
            let services = try await serviceIDs(userID: userID)
            let matching = Set(AvailabilityGroups(snapshot: snapshot, services: services).atServices(services).map(\.providerID))
            let known = try await AvailabilityNotice.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).all()
            for notice in known where !matching.contains(notice.providerID) {
                try await notice.delete(on: db)
            }
            let knownIDs = Set(known.map(\.providerID))
            let state: NoticeState = !entry.baselined ? .baseline : (user.notifyAvailable == true ? .pending : .skipped)
            for providerID in matching.subtracting(knownIDs).sorted() {
                try await ignoringDuplicate {
                    try await AvailabilityNotice(userID: userID, titleID: titleID, providerID: providerID, noticedAt: now, state: state)
                        .create(on: db)
                }
            }
            if !entry.baselined {
                entry.baselined = true
                try await entry.save(on: db)
            }
        }
    }

    /// Marks all of the user's entries so the next fetch records the present offers as known (services, country or the
    /// switch changed).
    /// - Parameter userID: The user.
    /// - Throws: Database errors.
    func rebaseline(userID: UUID) async throws {
        try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).set(\.$baselined, to: false).update()
    }

    /// Switching the notification on: offers still waiting from before (no channel, failed send) are not reported.
    ///
    /// Their state changes from `.pending` to `.skipped`.
    /// - Parameter userID: The user.
    /// - Throws: Database errors.
    func dropPending(userID: UUID) async throws {
        try await AvailabilityNotice.query(on: db).filter(\.$user.$id == userID).filter(\.$state == NoticeState.pending.rawValue)
            .set(\.$state, to: NoticeState.skipped.rawValue).update()
    }

    /// Pending offers of titles still on the list whose offer still exists, one item per title, by name.
    ///
    /// Only subscription, free and ad-supported offers (``AvailabilityService/notifyKinds``) in the user's country count;
    /// titles whose pending offers all disappeared are left out.
    /// - Parameter userID: The user.
    /// - Returns: The digest items, sorted case-insensitively by title name.
    /// - Throws: Database errors.
    func due(userID: UUID) async throws -> [AvailabilityDue] {
        let pending = try await AvailabilityNotice.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$state == NoticeState.pending.rawValue).all()
        guard !pending.isEmpty, let user = try await User.find(userID, on: db) else { return [] }
        let titleIDs = Array(Set(pending.map(\.$title.id)))
        let listed = Set(try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
            .map(\.$title.id))
        let titles = try await Title.query(on: db).filter(\.$id ~~ Array(listed)).all()
        let snapshots = try await AvailabilityService(db: db).snapshots(titleIDs: Array(listed), region: user.region)
        var items: [AvailabilityDue] = []
        for title in titles {
            guard let titleID = title.id, let snapshot = snapshots[titleID] else { continue }
            let notices = pending.filter { $0.$title.id == titleID }
            let ids = Set(notices.map(\.providerID))
            let offers = snapshot.offers.filter { ids.contains($0.providerID) && AvailabilityService.notifyKinds.contains($0.kind) }
            var names: [String] = []
            for offer in offers where !names.contains(offer.name) { names.append(offer.name) }
            let live = notices.filter { notice in offers.contains { $0.providerID == notice.providerID } }
            guard !names.isEmpty else { continue }
            items.append(AvailabilityDue(titleID: titleID, tmdbID: title.tmdbID, kind: title.titleKind, name: title.name, year: title.year,
                                         providers: names, noticeIDs: live.compactMap(\.id)))
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Marks the items' notices as sent.
    ///
    /// Called only after the digest was sent successfully.
    /// - Parameter items: The items that were sent.
    /// - Throws: Database errors.
    func markSent(_ items: [AvailabilityDue]) async throws {
        let ids = items.flatMap(\.noticeIDs)
        guard !ids.isEmpty else { return }
        for chunk in ids.chunked() {
            try await AvailabilityNotice.query(on: db).filter(\.$id ~~ Array(chunk)).set(\.$state, to: NoticeState.sent.rawValue).update()
        }
    }

    /// Titles with an offer that appeared at or after `since` (not a baseline), with the earliest such time („neu seit“).
    /// - Parameters:
    ///   - userID: The user.
    ///   - since: The start of the window.
    /// - Returns: For each such title ID, the earliest time a new offer was recorded.
    /// - Throws: Database errors.
    func newSince(userID: UUID, since: Date) async throws -> [UUID: Date] {
        let notices = try await AvailabilityNotice.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$state != NoticeState.baseline.rawValue).filter(\.$noticedAt >= since).all()
        var result: [UUID: Date] = [:]
        for notice in notices {
            result[notice.$title.id] = min(result[notice.$title.id] ?? notice.noticedAt, notice.noticedAt)
        }
        return result
    }

    /// The user's services (TMDB provider ids).
    /// - Parameter userID: The user.
    /// - Returns: The provider ids of the user's streaming services.
    /// - Throws: Database errors.
    func serviceIDs(userID: UUID) async throws -> Set<Int> {
        Set(try await UserStreamingService.query(on: db).filter(\.$user.$id == userID).all().map(\.providerID))
    }
}

/// Runs `insert`, ignoring a unique-constraint failure (a concurrent request inserted the same row first).
/// - Parameter insert: The insert to run.
/// - Throws: Any error of `insert` other than a constraint failure (any kind is ignored, not only unique ones).
func ignoringDuplicate(_ insert: () async throws -> Void) async throws {
    do {
        try await insert()
    } catch let error as any DatabaseError where error.isConstraintFailure {
        return
    }
}
