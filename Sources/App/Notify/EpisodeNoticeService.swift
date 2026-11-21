import Fluent
import Foundation

/// One episode in a user's digest, with every kind it covers (all are recorded when the digest goes out).
struct DueNotice: Equatable, Sendable {
    /// ID of the cached episode row.
    let episodeID: UUID
    let tmdbEpisodeID: Int
    let seriesTMDBID: Int
    let seriesName: String
    let season: Int
    let number: Int
    let name: String
    /// Valid `yyyy-MM-dd` or nil („Termin noch offen“).
    let airDate: String?
    /// Every notice kind due for this episode.
    let kinds: Set<NoticeKind>

    /// The section the episode is listed in.
    var headline: NoticeKind { kinds.min()! }
}

/// Which notices are due for followed series (spec §4), recording what went out, cleaning up old records.
struct EpisodeNoticeService {
    /// „Neu angekündigt“ is reported only for episodes undated or aired at most this many days ago.
    static let announcedMaxAge = 7
    /// Days before the air date that count as „In den nächsten Tagen“.
    static let soonDays = 1...3
    /// Days after the air date that sent-notice records are kept.
    static let keepDays = 30

    /// The database holding the catalog and the notices.
    let db: any Database

    /// The notices due for a user today, one item per episode.
    ///
    /// Only current episodes (season ≥ 1) of followed series count, and only kinds whose switch is on:
    /// - `announced`: first seen at TMDB after the later of the follow and switching the notice on (a renumbered episode
    ///   counts from its earliest row), undated, upcoming or aired at most 7 days ago, and never announced before;
    /// - `soon`: airs in 1–3 days, not yet sent for that air date;
    /// - `today`: airs today, not yet sent for that air date.
    ///
    /// Sent notices are matched by title and TMDB episode id, so a renumbered row counts as already sent; `soon` and
    /// `today` also match the air date, so a postponed episode is reminded again.
    /// - Parameters:
    ///   - user: The user.
    ///   - today: Today as `YYYY-MM-DD`.
    /// - Returns: The due items, sorted by series name, series, season and episode.
    /// - Throws: Fluent's error for a user without ID, or database errors.
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
        let firstSeen = try await earliestSeen(of: episodes, announcedOn: announcedOn)

        var due: [DueNotice] = []
        for episode in episodes {
            guard let episodeID = episode.id, let title = titleByID[episode.$title.id],
                  episode.isCurrent(titleRefreshedAt: title.refreshedAt) else { continue }
            let airDate = episode.airDate.flatMap { CalendarDay.isValid($0) ? $0 : nil }
            let sibling = SentKey(titleID: episode.$title.id, tmdbEpisodeID: episode.tmdbEpisodeID)
            var kinds = Set<NoticeKind>()
            let windowStart = [entryByTitle[episode.$title.id]?.followedAt, user.notifyAnnouncedSince].compactMap { $0 }.max() ?? .distantPast
            // A renumbered episode (same TMDB id in another row) counts from when its earliest row was first seen.
            if announcedOn, let seen = firstSeen[sibling] ?? episode.firstSeenAt, seen > windowStart,
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
    ///
    /// Called only after the digest was sent successfully.
    /// - Parameters:
    ///   - due: The items that were sent.
    ///   - userID: The recipient.
    ///   - now: The sending time.
    /// - Throws: Database errors.
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
    /// - Parameter today: Today as `YYYY-MM-DD`.
    /// - Returns: The number of deleted records.
    /// - Throws: Database errors.
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

    /// Earliest first-seen time per title + TMDB episode id over all rows (also stale ones); `.distantPast` when any
    /// row predates first-seen tracking. Only for rows that could be announced.
    /// - Parameters:
    ///   - episodes: The candidate episodes.
    ///   - announcedOn: Whether the user wants „Neu angekündigt“; when off, nothing is loaded.
    /// - Returns: The earliest first-seen time per title and TMDB episode id.
    /// - Throws: Database errors.
    private func earliestSeen(of episodes: [Episode], announcedOn: Bool) async throws -> [SentKey: Date] {
        guard announcedOn else { return [:] }
        let candidates = episodes.filter { $0.firstSeenAt != nil }
        guard !candidates.isEmpty else { return [:] }
        let rows = try await Episode.query(on: db).filter(\.$title.$id ~~ Array(Set(candidates.map(\.$title.id))))
            .filter(\.$tmdbEpisodeID ~~ Array(Set(candidates.map(\.tmdbEpisodeID))))
            .field(\.$id).field(\.$title.$id).field(\.$tmdbEpisodeID).field(\.$firstSeenAt).all()
        var earliest: [SentKey: Date] = [:]
        for row in rows {
            let key = SentKey(titleID: row.$title.id, tmdbEpisodeID: row.tmdbEpisodeID)
            earliest[key] = min(earliest[key] ?? .distantFuture, row.firstSeenAt ?? .distantPast)
        }
        return earliest
    }

    /// What the user already got, keyed by title + TMDB episode id, so a renumbered row (same TMDB id) counts too.
    /// - Parameter userID: The user.
    /// - Returns: The keys of all sent notices (the air date only for `soon`/`today`).
    /// - Throws: Database errors.
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

/// Identifies an episode across renumbering: title plus TMDB episode id.
private struct SentKey: Hashable {
    let titleID: UUID
    let tmdbEpisodeID: Int

    /// A ``SentKey`` with notice kind and air date, matching one sent notice.
    struct Full: Hashable {
        let base: SentKey
        let kind: NoticeKind
        let airDate: String?
    }

    /// The full key for a notice kind.
    /// - Parameters:
    ///   - kind: The notice kind.
    ///   - airDate: The air date (nil for `announced`).
    /// - Returns: The combined key.
    func with(_ kind: NoticeKind, airDate: String?) -> Full { Full(base: self, kind: kind, airDate: airDate) }
}
