import Fluent
import Foundation
import Vapor

enum TrackingError: Error, Equatable {
    case notFound, invalidRating, invalidDate, futureDate, notAired, commentTooLong
}

/// All per-user tracking writes. Every method takes the acting user's ID and never
/// touches another user's rows (foreign IDs → `.notFound`).
struct WatchService {
    let db: any Database
    var today: @Sendable () -> String = { CalendarDay.today() }

    // MARK: Episodes

    func markEpisode(userID: UUID, episodeID: UUID, day: String?, service: StreamingService?, rewatch: Bool = false) async throws -> Watch {
        guard let episode = try await Episode.find(episodeID, on: db) else { throw TrackingError.notFound }
        let watchedOn = try resolveDay(day)
        guard isAired(episode) else { throw TrackingError.notAired }
        try await unhide(userID: userID, titleID: episode.$title.id)
        if !rewatch, let existing = try await watchesQuery(userID: userID).filter(\.$episode.$id == episodeID)
            .sort(\.$createdAt, .descending).first() {
            return existing
        }
        let watch = Watch(userID: userID, titleID: episode.$title.id, episodeID: episodeID, watchedOn: watchedOn, service: service, origin: .manual)
        try await watch.save(on: db)
        return watch
    }

    func unmarkEpisode(userID: UUID, episodeID: UUID) async throws {
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$episode.$id == episodeID))
    }

    func markSeason(userID: UUID, titleID: UUID, season: Int, service: StreamingService?) async throws -> Int {
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let episodes = try await Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$season == season).all()
        return try await markUndated(userID: userID, titleID: titleID, episodes: episodes, service: service)
    }

    /// All aired regular episodes (season ≥ 1) of a series, undated – „Gesamte Serie gesehen“.
    func markSeries(userID: UUID, titleID: UUID, service: StreamingService?) async throws -> Int {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let episodes = try await Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$season >= 1).all()
        return try await markUndated(userID: userID, titleID: titleID, episodes: episodes, service: service)
    }

    func markUpTo(userID: UUID, episodeID: UUID, service: StreamingService?) async throws -> Int {
        guard let target = try await Episode.find(episodeID, on: db) else { throw TrackingError.notFound }
        let all = try await Episode.query(on: db).filter(\.$title.$id == target.$title.id).all()
        let selected = all.filter { e in
            if target.season == 0 { return e.season == 0 && e.number <= target.number }
            return e.season >= 1 && (e.season < target.season || (e.season == target.season && e.number <= target.number))
        }
        return try await markUndated(userID: userID, titleID: target.$title.id, episodes: selected, service: service)
    }

    // MARK: Movies

    func markMovie(userID: UUID, titleID: UUID, day: String?, service: StreamingService?, rewatch: Bool = false) async throws -> Watch {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .movie else { throw TrackingError.notFound }
        let watchedOn = try resolveDay(day)
        _ = try await userTitle(userID: userID, titleID: titleID)
        if !rewatch, let existing = try await watchesQuery(userID: userID).filter(\.$title.$id == titleID)
            .filter(\.$episode.$id == nil).sort(\.$createdAt, .descending).first() {
            return existing
        }
        let watch = Watch(userID: userID, titleID: titleID, episodeID: nil, watchedOn: watchedOn, service: service, origin: .manual)
        try await watch.save(on: db)
        return watch
    }

    func unmarkMovie(userID: UUID, titleID: UUID) async throws {
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$episode.$id == nil))
    }

    // MARK: Imported watches

    /// Records a watch found in a Netflix export (§6.2 step 5): merges into a manual watch of the
    /// same episode/movie with service Netflix or unknown that is dated within ±1 day (closest first)
    /// or undated (takes the CSV date); otherwise inserts an import watch. Never unhides.
    func recordImportedWatch(userID: UUID, titleID: UUID, episodeID: UUID?, day: String) async throws -> Watch {
        _ = try await userTitle(userID: userID, titleID: titleID)
        var query = watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$origin == WatchOrigin.manual.rawValue)
        query = episodeID.map { id in query.filter(\.$episode.$id == id) } ?? query.filter(\.$episode.$id == nil)
        let candidates = try await query.all().filter { $0.service == nil || $0.streamingService == .netflix }
        let dated = candidates.compactMap { watch -> (Watch, Int)? in
            guard let on = watch.watchedOn else { return nil }
            let distance = abs(CalendarDay.daysBetween(on, day))
            return distance <= 1 ? (watch, distance) : nil
        }
        if let (watch, _) = dated.min(by: { $0.1 < $1.1 }) { return watch }
        if let undated = candidates.first(where: { $0.watchedOn == nil }) {
            undated.watchedOn = day
            try await undated.save(on: db)
            return undated
        }
        let watch = Watch(userID: userID, titleID: titleID, episodeID: episodeID, watchedOn: day, service: .netflix, origin: .import)
        try await watch.save(on: db)
        return watch
    }

    // MARK: Single watches

    func editWatch(userID: UUID, watchID: UUID, day: String?, service: StreamingService?) async throws {
        let watch = try await ownWatch(userID: userID, watchID: watchID)
        watch.watchedOn = try day.map { try resolveDay($0) }
        watch.service = service?.rawValue
        try await watch.save(on: db)
    }

    func deleteWatch(userID: UUID, watchID: UUID) async throws {
        try await ownWatch(userID: userID, watchID: watchID)
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$id == watchID))
    }

    // MARK: Library entry

    func setRating(userID: UUID, titleID: UUID, rating: Int?) async throws {
        if let rating, !(1...10).contains(rating) { throw TrackingError.invalidRating }
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.rating = rating
        try await entry.save(on: db)
    }

    func setHidden(userID: UUID, titleID: UUID, hidden: Bool) async throws {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.hidden = hidden
        try await entry.save(on: db)
    }

    // MARK: Follow („Beobachten“)

    func setFollowed(userID: UUID, titleID: UUID, followed: Bool, now: Date = .now) async throws {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        if followed && !(entry.isFollowed && entry.followedOn != nil) {
            entry.followedOn = today()
            entry.followedAt = now
        }
        entry.followed = followed
        if !followed {
            entry.followedOn = nil
            entry.followedAt = nil
        }
        try await entry.save(on: db)
    }

    /// „Erledigt“ on the new-episodes note: episodes aired up to today no longer count as new.
    func dismissNewEpisodes(userID: UUID, titleID: UUID) async throws {
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.newSeenUntil = today()
        try await entry.save(on: db)
    }

    // MARK: Comments

    static let maxCommentLength = 2000

    /// Trimmed comment, nil when empty; throws when longer than 2000 characters.
    private func cleanComment(_ comment: String?) throws -> String? {
        let text = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxCommentLength else { throw TrackingError.commentTooLong }
        return text.isEmpty ? nil : text
    }

    func setComment(userID: UUID, titleID: UUID, comment: String?) async throws {
        let text = try cleanComment(comment)
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.comment = text
        try await entry.save(on: db)
    }

    func setSeasonComment(userID: UUID, titleID: UUID, season: Int, comment: String?) async throws {
        let text = try cleanComment(comment)
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let existing = try await SeasonNote.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID)
            .filter(\.$season == season).first()
        switch (existing, text) {
        case let (note?, text?):
            note.comment = text
            try await note.save(on: db)
        case let (note?, nil):
            try await note.delete(on: db)
        case let (nil, text?):
            try await SeasonNote(userID: userID, titleID: titleID, season: season, comment: text).save(on: db)
        case (nil, nil):
            break
        }
    }

    func seasonComments(userID: UUID, titleID: UUID) async throws -> [Int: String] {
        let notes = try await SeasonNote.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).all()
        return Dictionary(notes.map { ($0.season, $0.comment) }, uniquingKeysWith: { a, _ in a })
    }

    /// Service of the most recent watch that has one (dated watches first).
    func lastService(userID: UUID, titleID: UUID) async throws -> StreamingService? {
        try await watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$service != nil)
            .sort(\.$watchedOn, .descending).sort(\.$createdAt, .descending).first()?.streamingService
    }

    /// Get-or-create the user's library entry for a title.
    func userTitle(userID: UUID, titleID: UUID) async throws -> UserTitle {
        if let entry = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() {
            return entry
        }
        let entry = UserTitle(userID: userID, titleID: titleID)
        try await entry.save(on: db)
        return entry
    }

    // MARK: Helpers

    func watchesQuery(userID: UUID) -> QueryBuilder<Watch> {
        Watch.query(on: db).filter(\.$user.$id == userID)
    }

    /// Deletes the selected watches; Netflix rows linked to them become `discarded` so a
    /// re-import does not bring them back.
    private func deleteDiscardingRows(_ query: QueryBuilder<Watch>) async throws {
        let ids = try await query.all().compactMap(\.id)
        guard !ids.isEmpty else { return }
        try await db.transaction { db in
            try await NetflixRow.query(on: db).filter(\.$watch.$id ~~ ids)
                .set(\.$status, to: RowStatus.discarded.rawValue).update()
            try await Watch.query(on: db).filter(\.$id ~~ ids).delete()
        }
    }

    @discardableResult
    private func ownWatch(userID: UUID, watchID: UUID) async throws -> Watch {
        guard let watch = try await watchesQuery(userID: userID).filter(\.$id == watchID).first() else { throw TrackingError.notFound }
        return watch
    }

    private func resolveDay(_ day: String?) throws -> String {
        let today = today()
        guard let day, !day.isEmpty else { return today }
        guard CalendarDay.isValid(day) else { throw TrackingError.invalidDate }
        guard day <= today else { throw TrackingError.futureDate }
        return day
    }

    func isAired(_ episode: Episode) -> Bool {
        guard let airDate = episode.airDate else { return false }
        return airDate <= today()
    }

    private func unhide(userID: UUID, titleID: UUID) async throws {
        let entry = try await userTitle(userID: userID, titleID: titleID)
        if entry.hidden {
            entry.hidden = false
            try await entry.save(on: db)
        }
    }

    private func markUndated(userID: UUID, titleID: UUID, episodes: [Episode], service: StreamingService?) async throws -> Int {
        let watched = Set(try await watchesQuery(userID: userID).filter(\.$title.$id == titleID).all().compactMap(\.$episode.id))
        let toMark = episodes.filter { isAired($0) && !watched.contains($0.id!) }
        try await unhide(userID: userID, titleID: titleID)
        for episode in toMark {
            try await Watch(userID: userID, titleID: titleID, episodeID: episode.requireID(), watchedOn: nil,
                            service: service, origin: .manual).save(on: db)
        }
        return toMark.count
    }
}

extension Request {
    var watches: WatchService { WatchService(db: db, today: application.appConfig.today) }
}
