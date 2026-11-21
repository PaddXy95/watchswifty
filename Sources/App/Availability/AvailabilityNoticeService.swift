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
    let noticeIDs: [UUID]
}

/// Which offers of „Später ansehen“ titles a user already knows (spec §4.3, §6).
struct AvailabilityNoticeService {
    let db: any Database

    /// After a successful fetch of the title: per list entry whose user's country the fetch covered, records offers at
    /// the user's services as `.baseline` (entry not yet baselined) or as new (`.pending` / `.skipped`), and forgets
    /// offers that are gone, so a return is reported again.
    func reconcile(titleID: UUID, now: Date = .now) async throws {
        let entries = try await WatchLaterEntry.query(on: db).filter(\.$title.$id == titleID).all()
        guard !entries.isEmpty else { return }
        let availability = AvailabilityService(db: db)
        for entry in entries {
            guard let user = try await User.find(entry.$user.id, on: db),
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
                try await AvailabilityNotice(userID: userID, titleID: titleID, providerID: providerID, noticedAt: now, state: state)
                    .create(on: db)
            }
            if !entry.baselined {
                entry.baselined = true
                try await entry.save(on: db)
            }
        }
    }

    /// Marks all of the user's entries so the next fetch records the present offers as known (services, country or the
    /// switch changed).
    func rebaseline(userID: UUID) async throws {
        try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).set(\.$baselined, to: false).update()
    }

    /// Pending offers of titles still on the list whose offer still exists, one item per title, by name.
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
    func markSent(_ items: [AvailabilityDue]) async throws {
        let ids = items.flatMap(\.noticeIDs)
        guard !ids.isEmpty else { return }
        for chunk in ids.chunked() {
            try await AvailabilityNotice.query(on: db).filter(\.$id ~~ Array(chunk)).set(\.$state, to: NoticeState.sent.rawValue).update()
        }
    }

    /// Titles with an offer that appeared at or after `since` (not a baseline), with the earliest such time („neu seit“).
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
    func serviceIDs(userID: UUID) async throws -> Set<Int> {
        Set(try await UserStreamingService.query(on: db).filter(\.$user.$id == userID).all().map(\.providerID))
    }
}
