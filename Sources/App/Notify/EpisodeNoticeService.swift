import Fluent
import Foundation

/// One episode in a user's digest, with every kind it covers (all are recorded when the digest goes out).
struct DueNotice: Equatable, Sendable {
    let episodeID: UUID
    let tmdbEpisodeID: Int
    let seriesTMDBID: Int
    let seriesName: String
    let season: Int
    let number: Int
    let name: String
    /// Valid `yyyy-MM-dd` or nil („Termin noch offen“).
    let airDate: String?
    let kinds: Set<NoticeKind>

    /// The section the episode is listed in.
    var headline: NoticeKind { kinds.min()! }
}

/// Which notices are due for followed series (spec §4), recording what went out, cleaning up old records.
struct EpisodeNoticeService {
    static let announcedMaxAge = 7
    static let soonDays = 1...3
    static let keepDays = 30

    let db: any Database

    func due(for user: User, today: String) async throws -> [DueNotice] {
        let announcedOn = user.notifyAnnounced == true, soonOn = user.notifySoon == true, todayOn = user.notifyToday == true
        guard announcedOn || soonOn || todayOn else { return [] }
        let userID = try user.requireID()
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$followed == true).all()
        guard !entries.isEmpty else { return [] }
        let titles = try await Title.query(on: db).filter(\.$id ~~ entries.map(\.$title.id)).filter(\.$kind == TitleKind.tv.rawValue).all()
        guard !titles.isEmpty else { return [] }
        let titleByID = Dictionary(titles.compactMap { title in title.id.map { ($0, title) } }, uniquingKeysWith: { a, _ in a })
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Only rows that can be due: first seen at some point, or airing within the reminder window.
        let windowEnd = CalendarDay.adding(days: Self.soonDays.upperBound, to: today)
        let episodes = try await Episode.query(on: db).filter(\.$title.$id ~~ Array(titleByID.keys)).filter(\.$season >= 1)
            .group(.or) { group in
                group.filter(\.$firstSeenAt != nil)
                group.group(.and) { $0.filter(\.$airDate >= today).filter(\.$airDate <= windowEnd) }
            }.all()
        let sent = try await sentKeys(userID: userID)

        var due: [DueNotice] = []
        for episode in episodes {
            guard let episodeID = episode.id, let title = titleByID[episode.$title.id],
                  episode.isCurrent(titleRefreshedAt: title.refreshedAt) else { continue }
            let airDate = episode.airDate.flatMap { CalendarDay.isValid($0) ? $0 : nil }
            let sibling = SentKey(titleID: episode.$title.id, tmdbEpisodeID: episode.tmdbEpisodeID)
            var kinds = Set<NoticeKind>()
            let windowStart = [entryByTitle[episode.$title.id]?.followedAt, user.notifyAnnouncedSince].compactMap { $0 }.max() ?? .distantPast
            if announcedOn, let seen = episode.firstSeenAt, seen > windowStart,
               airDate.map({ CalendarDay.daysBetween($0, today) <= Self.announcedMaxAge }) ?? true,
               !sent.contains(sibling.with(.announced, airDate: nil)) {
                kinds.insert(.announced)
            }
            if soonOn, let airDate, Self.soonDays.contains(CalendarDay.daysBetween(today, airDate)),
               !sent.contains(sibling.with(.soon, airDate: airDate)) {
                kinds.insert(.soon)
            }
            if todayOn, let airDate, airDate == today, !sent.contains(sibling.with(.today, airDate: airDate)) {
                kinds.insert(.today)
            }
            guard !kinds.isEmpty else { continue }
            due.append(DueNotice(episodeID: episodeID, tmdbEpisodeID: episode.tmdbEpisodeID, seriesTMDBID: title.tmdbID,
                                 seriesName: title.name, season: episode.season, number: episode.number, name: episode.name,
                                 airDate: airDate, kinds: kinds))
        }
        return due.sorted {
            let order = $0.seriesName.localizedCaseInsensitiveCompare($1.seriesName)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.seriesTMDBID != $1.seriesTMDBID { return $0.seriesTMDBID < $1.seriesTMDBID }
            return ($0.season, $0.number) < ($1.season, $1.number)
        }
    }

    /// One row per (episode, kind): inserted, or updated with the current date.
    func record(_ due: [DueNotice], userID: UUID, now: Date) async throws {
        guard !due.isEmpty else { return }
        let existing = try await EpisodeNotice.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$episode.$id ~~ due.map(\.episodeID)).all()
        // Each (episode, kind) appears once in `due`, so no key is written twice.
        let byKey = Dictionary(existing.map { ("\($0.$episode.id)|\($0.kind)", $0) }, uniquingKeysWith: { a, _ in a })
        try await db.transaction { db in
            for item in due {
                for kind in item.kinds {
                    let key = "\(item.episodeID)|\(kind.rawValue)"
                    if let notice = byKey[key] {
                        notice.airDate = item.airDate
                        notice.sentAt = now
                        try await notice.save(on: db)
                    } else {
                        try await EpisodeNotice(userID: userID, episodeID: item.episodeID, kind: kind, airDate: item.airDate,
                                                sentAt: now).save(on: db)
                    }
                }
            }
        }
    }

    /// Deletes notices whose episode – by its current date – aired more than 30 days ago; nothing is due for those
    /// any more, so nothing comes twice. Notices of undated episodes stay.
    @discardableResult
    func cleanup(today: String) async throws -> Int {
        let cutoff = CalendarDay.adding(days: -Self.keepDays, to: today)
        let notices = try await EpisodeNotice.query(on: db).all()
        guard !notices.isEmpty else { return 0 }
        let old = Set(try await Episode.query(on: db).filter(\.$id ~~ Array(Set(notices.map(\.$episode.id))))
            .filter(\.$airDate < cutoff).all()
            .filter { $0.airDate.map(CalendarDay.isValid) ?? false }.compactMap(\.id))
        let doomed = notices.filter { old.contains($0.$episode.id) }
        guard !doomed.isEmpty else { return 0 }
        try await EpisodeNotice.query(on: db).filter(\.$id ~~ doomed.compactMap(\.id)).delete()
        return doomed.count
    }

    /// What the user already got, keyed by title + TMDB episode id, so a renumbered row (same TMDB id) counts too.
    private func sentKeys(userID: UUID) async throws -> Set<SentKey.Full> {
        let notices = try await EpisodeNotice.query(on: db).filter(\.$user.$id == userID).all()
        guard !notices.isEmpty else { return [] }
        let episodes = try await Episode.query(on: db).filter(\.$id ~~ Array(Set(notices.map(\.$episode.id)))).all()
        let byID = Dictionary(episodes.compactMap { episode in episode.id.map { ($0, episode) } }, uniquingKeysWith: { a, _ in a })
        return Set(notices.compactMap { notice -> SentKey.Full? in
            guard let episode = byID[notice.$episode.id], let kind = NoticeKind(rawValue: notice.kind) else { return nil }
            return SentKey(titleID: episode.$title.id, tmdbEpisodeID: episode.tmdbEpisodeID)
                .with(kind, airDate: kind == .announced ? nil : notice.airDate)
        })
    }
}

private struct SentKey: Hashable {
    let titleID: UUID
    let tmdbEpisodeID: Int

    struct Full: Hashable {
        let base: SentKey
        let kind: NoticeKind
        let airDate: String?
    }

    func with(_ kind: NoticeKind, airDate: String?) -> Full { Full(base: self, kind: kind, airDate: airDate) }
}
