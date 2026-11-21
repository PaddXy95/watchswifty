import Fluent
import Foundation
import Vapor

/// Domain errors of the tracking writes; `HTMLErrorMiddleware` maps them to HTTP statuses with German messages.
///
/// `notFound`: unknown or foreign record (another user's IDs count as missing); `invalidRating`: not 1…10;
/// `invalidDate`: not a valid `YYYY-MM-DD` day; `futureDate`: a day after today; `notAired`: the episode has not
/// aired yet; `commentTooLong`: more than ``WatchService/maxCommentLength`` characters.
enum TrackingError: Error, Equatable {
    case notFound, invalidRating, invalidDate, futureDate, notAired, commentTooLong
}

/// All per-user tracking writes. Every method takes the acting user's ID and never
/// touches another user's rows (foreign IDs → `.notFound`).
struct WatchService {
    let db: any Database
    /// Returns the current day (`YYYY-MM-DD`); for requests `AppConfig.today()` (see `req.watches`), pinned in tests.
    var today: @Sendable () -> String = { CalendarDay.today() }

    // MARK: Episodes

    /// Records a watch of an episode, dated `day` (today when nil).
    ///
    /// Unhides the series. Without `rewatch` an existing watch of the episode is returned instead of adding a second one;
    /// with it („Erneut gesehen“, watched again) a new watch is always added. A new watch takes the title off the
    /// „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - episodeID: The episode.
    ///   - day: The day watched (`YYYY-MM-DD`), or nil/empty for today.
    ///   - service: The streaming service, if any.
    ///   - rewatch: Whether to add a new viewing even when the episode is already watched.
    /// - Returns: The new watch, or the newest existing one.
    /// - Throws: `TrackingError.notFound` for an unknown episode, `.invalidDate`, `.futureDate`, or `.notAired` when the
    ///   episode has not aired by today.
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
        try await WatchLaterService(db: db).removeAfterWatch(userID: userID, titleID: episode.$title.id, day: watchedOn, origin: .manual)
        return watch
    }

    /// Deletes all of the user's watches of an episode; linked Netflix import rows become `discarded`.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - episodeID: The episode.
    /// - Throws: Database errors.
    func unmarkEpisode(userID: UUID, episodeID: UUID) async throws {
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$episode.$id == episodeID))
    }

    /// „Ganze Staffel gesehen“; with `rewatch` („… erneut gesehen“) a new round, see `markRound`.
    ///
    /// Without `rewatch`, every aired episode of the season the user has not watched yet gets one undated watch.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - season: The season number.
    ///   - service: The streaming service for the new watches, if any.
    ///   - rewatch: Whether to mark a new round instead of only the missing episodes.
    /// - Returns: The number of watches added.
    /// - Throws: `TrackingError.notFound` for an unknown title.
    func markSeason(userID: UUID, titleID: UUID, season: Int, service: StreamingService?, rewatch: Bool = false) async throws -> Int {
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let episodes = try await Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$season == season).all()
        return rewatch
            ? try await markRound(userID: userID, titleID: titleID, episodes: episodes, service: service)
            : try await markUndated(userID: userID, titleID: titleID, episodes: episodes, service: service)
    }

    /// All aired regular episodes (season ≥ 1) of a series, undated – „Gesamte Serie gesehen“; with `rewatch` a new
    /// round, see `markRound`.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - service: The streaming service for the new watches, if any.
    ///   - rewatch: Whether to mark a new round instead of only the missing episodes.
    /// - Returns: The number of watches added.
    /// - Throws: `TrackingError.notFound` when the title is unknown or not a series.
    func markSeries(userID: UUID, titleID: UUID, service: StreamingService?, rewatch: Bool = false) async throws -> Int {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let episodes = try await Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$season >= 1).all()
        return rewatch
            ? try await markRound(userID: userID, titleID: titleID, episodes: episodes, service: service)
            : try await markUndated(userID: userID, titleID: titleID, episodes: episodes, service: service)
    }

    /// „bis hier gesehen“ (watched up to here): one undated watch for every aired, unwatched episode up to and including
    /// the given one.
    ///
    /// For a regular episode that is every regular episode of earlier seasons and of its season up to its number; for a
    /// special (season 0) only the specials up to its number.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - episodeID: The last episode to mark.
    ///   - service: The streaming service for the new watches, if any.
    /// - Returns: The number of watches added.
    /// - Throws: `TrackingError.notFound` for an unknown episode.
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

    /// Records a watch of a movie, dated `day` (today when nil), and creates the user's library entry if needed.
    ///
    /// Without `rewatch` an existing watch of the movie is returned instead of adding a second one. A new watch takes the
    /// movie off the „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The movie.
    ///   - day: The day watched (`YYYY-MM-DD`), or nil/empty for today.
    ///   - service: The streaming service, if any.
    ///   - rewatch: Whether to add a new viewing even when the movie is already watched.
    /// - Returns: The new watch, or the newest existing one.
    /// - Throws: `TrackingError.notFound` when the title is unknown or not a movie, `.invalidDate`, `.futureDate`.
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
        try await WatchLaterService(db: db).removeAfterWatch(userID: userID, titleID: titleID, day: watchedOn, origin: .manual)
        return watch
    }

    /// Deletes all of the user's watches of a movie; linked Netflix import rows become `discarded`.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The movie.
    /// - Throws: Database errors.
    func unmarkMovie(userID: UUID, titleID: UUID) async throws {
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$episode.$id == nil))
    }

    // MARK: Imported watches

    /// Records a watch found in a Netflix export (§6.2 step 5): merges into a manual watch of the
    /// same episode/movie with service Netflix or unknown that is dated within ±1 day (closest first)
    /// or undated (takes the CSV date); otherwise inserts an import watch. Never unhides.
    /// - Parameters:
    ///   - userID: The importing user.
    ///   - titleID: The series or movie.
    ///   - episodeID: The episode, or nil for a movie.
    ///   - day: The viewing day from the export (`YYYY-MM-DD`).
    /// - Returns: The matched manual watch or the new import watch. Only a new import watch takes the title off the
    ///   „Später ansehen“ list (and only when dated on or after the day it was added).
    /// - Throws: Database errors.
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
        try await WatchLaterService(db: db).removeAfterWatch(userID: userID, titleID: titleID, day: day, origin: .import)
        return watch
    }

    // MARK: Single watches

    /// Changes the day and service of one of the user's watches.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - watchID: The watch.
    ///   - day: The new day (`YYYY-MM-DD`); nil makes the watch undated, an empty string dates it today.
    ///   - service: The new service, or nil for none.
    /// - Throws: `TrackingError.notFound` for a missing or another user's watch, `.invalidDate`, `.futureDate`.
    func editWatch(userID: UUID, watchID: UUID, day: String?, service: StreamingService?) async throws {
        let watch = try await ownWatch(userID: userID, watchID: watchID)
        watch.watchedOn = try day.map { try resolveDay($0) }
        watch.service = service?.rawValue
        try await watch.save(on: db)
    }

    /// Deletes one of the user's watches; a linked Netflix import row becomes `discarded`.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - watchID: The watch.
    /// - Throws: `TrackingError.notFound` for a missing or another user's watch.
    func deleteWatch(userID: UUID, watchID: UUID) async throws {
        try await ownWatch(userID: userID, watchID: watchID)
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$id == watchID))
    }

    /// Deletes one viewing from the episode's or movie's own page; `episodeID` nil = a movie watch. A watch of another
    /// title or episode counts as not found, like another user's.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - watchID: The watch.
    ///   - titleID: The title whose page the request came from.
    ///   - episodeID: The episode whose details the request came from, or nil for a movie.
    /// - Throws: `TrackingError.notFound` when the watch is missing, another user's, or belongs to another title or
    ///   episode.
    func deleteWatch(userID: UUID, watchID: UUID, titleID: UUID, episodeID: UUID?) async throws {
        let watch = try await ownWatch(userID: userID, watchID: watchID)
        guard watch.$title.id == titleID, watch.$episode.id == episodeID else { throw TrackingError.notFound }
        try await deleteDiscardingRows(watchesQuery(userID: userID).filter(\.$id == watchID))
    }

    // MARK: Library entry

    /// Sets or clears the user's rating of a title, creating the library entry if needed.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series or movie.
    ///   - rating: 1…10, or nil to remove the rating.
    /// - Throws: `TrackingError.invalidRating` outside 1…10, `.notFound` for an unknown title.
    func setRating(userID: UUID, titleID: UUID, rating: Int?) async throws {
        if let rating, !(1...10).contains(rating) { throw TrackingError.invalidRating }
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.rating = rating
        try await entry.save(on: db)
    }

    /// „Ausblenden“ / „Einblenden“ (hide / show): sets whether a series is hidden from „Weiterschauen“ and the library.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - hidden: The new flag.
    /// - Throws: `TrackingError.notFound` when the title is unknown or not a series.
    func setHidden(userID: UUID, titleID: UUID, hidden: Bool) async throws {
        guard let title = try await Title.find(titleID, on: db), title.titleKind == .tv else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.hidden = hidden
        try await entry.save(on: db)
    }

    // MARK: Follow („Beobachten“)

    /// „Beobachten“ (follow): turns new-episode reminders for a series on or off.
    ///
    /// Following records the follow day (`today()`) and time unless the series is already followed with a follow day;
    /// unfollowing clears both.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - followed: The new state.
    ///   - now: The follow time stored in `followed_at`.
    /// - Throws: `TrackingError.notFound` when the title is unknown or not a series.
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
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    /// - Throws: `TrackingError.notFound` for an unknown title.
    func dismissNewEpisodes(userID: UUID, titleID: UUID) async throws {
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.newSeenUntil = today()
        try await entry.save(on: db)
    }

    // MARK: Comments

    static let maxCommentLength = 2000

    /// Trimmed comment, nil when empty; throws when longer than 2000 characters.
    /// - Parameter comment: The comment as entered.
    /// - Returns: The trimmed text, or nil.
    /// - Throws: `TrackingError.commentTooLong`.
    private func cleanComment(_ comment: String?) throws -> String? {
        let text = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxCommentLength else { throw TrackingError.commentTooLong }
        return text.isEmpty ? nil : text
    }

    /// Sets the user's private comment on a series or movie; an empty comment removes it.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series or movie.
    ///   - comment: The comment as entered (trimmed before saving).
    /// - Throws: `TrackingError.commentTooLong` over 2000 characters, `.notFound` for an unknown title.
    func setComment(userID: UUID, titleID: UUID, comment: String?) async throws {
        let text = try cleanComment(comment)
        guard try await Title.find(titleID, on: db) != nil else { throw TrackingError.notFound }
        let entry = try await userTitle(userID: userID, titleID: titleID)
        entry.comment = text
        try await entry.save(on: db)
    }

    /// Sets the user's private comment on one season of a series; an empty comment deletes it.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - season: The season number.
    ///   - comment: The comment as entered (trimmed before saving).
    /// - Throws: `TrackingError.commentTooLong` over 2000 characters, `.notFound` when the title is unknown or not a series.
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

    /// The user's season comments of a series.
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The series.
    /// - Returns: The comments keyed by season number.
    /// - Throws: Database errors.
    func seasonComments(userID: UUID, titleID: UUID) async throws -> [Int: String] {
        let notes = try await SeasonNote.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).all()
        return Dictionary(notes.map { ($0.season, $0.comment) }, uniquingKeysWith: { a, _ in a })
    }

    /// Service of the most recent watch that has one (dated watches first).
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The series or movie.
    /// - Returns: The service, or nil when no watch has one.
    /// - Throws: Database errors.
    func lastService(userID: UUID, titleID: UUID) async throws -> StreamingService? {
        try await watchesQuery(userID: userID).filter(\.$title.$id == titleID).filter(\.$service != nil)
            .sort(\.$watchedOn, .descending).sort(\.$createdAt, .descending).first()?.streamingService
    }

    /// Get-or-create the user's library entry for a title.
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The series or movie.
    /// - Returns: The existing entry, or a new visible, unrated one (saved).
    /// - Throws: Database errors.
    func userTitle(userID: UUID, titleID: UUID) async throws -> UserTitle {
        if let entry = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).first() {
            return entry
        }
        let entry = UserTitle(userID: userID, titleID: titleID)
        try await entry.save(on: db)
        return entry
    }

    // MARK: Helpers

    /// A query over the user's own watches; every watch read starts here so another user's rows never match.
    /// - Parameter userID: The user.
    /// - Returns: The filtered query builder.
    func watchesQuery(userID: UUID) -> QueryBuilder<Watch> {
        Watch.query(on: db).filter(\.$user.$id == userID)
    }

    /// Deletes the selected watches; Netflix rows linked to them become `discarded` so a
    /// re-import does not bring them back.
    /// - Parameter query: Selects the watches to delete (already limited to the acting user).
    /// - Throws: Database errors; both changes run in one transaction.
    private func deleteDiscardingRows(_ query: QueryBuilder<Watch>) async throws {
        let ids = try await query.all().compactMap(\.id)
        guard !ids.isEmpty else { return }
        try await db.transaction { db in
            try await NetflixRow.query(on: db).filter(\.$watch.$id ~~ ids)
                .set(\.$status, to: RowStatus.discarded.rawValue).update()
            try await Watch.query(on: db).filter(\.$id ~~ ids).delete()
        }
    }

    /// Loads one of the user's watches.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - watchID: The watch.
    /// - Returns: The watch.
    /// - Throws: `TrackingError.notFound` for a missing or another user's watch.
    @discardableResult
    private func ownWatch(userID: UUID, watchID: UUID) async throws -> Watch {
        guard let watch = try await watchesQuery(userID: userID).filter(\.$id == watchID).first() else { throw TrackingError.notFound }
        return watch
    }

    /// Validates a watch day; nil or empty means today.
    /// - Parameter day: The day as entered (`YYYY-MM-DD`).
    /// - Returns: The day to store.
    /// - Throws: `TrackingError.invalidDate` for a malformed day, `.futureDate` for a day after today.
    private func resolveDay(_ day: String?) throws -> String {
        let today = today()
        guard let day, !day.isEmpty else { return today }
        guard CalendarDay.isValid(day) else { throw TrackingError.invalidDate }
        guard day <= today else { throw TrackingError.futureDate }
        return day
    }

    /// Whether an episode has aired by `today()`; episodes without an air date count as not aired.
    /// - Parameter episode: The episode.
    /// - Returns: True when the air date is on or before today.
    func isAired(_ episode: Episode) -> Bool {
        guard let airDate = episode.airDate else { return false }
        return airDate <= today()
    }

    /// Clears the hidden flag of the user's library entry for a title (creating the entry if needed).
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The title.
    /// - Throws: Database errors.
    private func unhide(userID: UUID, titleID: UUID) async throws {
        let entry = try await userTitle(userID: userID, titleID: titleID)
        if entry.hidden {
            entry.hidden = false
            try await entry.save(on: db)
        }
    }

    /// Adds one undated watch for every aired episode in `episodes` the user has not watched yet.
    ///
    /// Unhides the series; when anything was added, the title leaves the „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - episodes: The candidate episodes.
    ///   - service: The streaming service for the new watches, if any.
    /// - Returns: The number of watches added.
    /// - Throws: Database errors.
    private func markUndated(userID: UUID, titleID: UUID, episodes: [Episode], service: StreamingService?) async throws -> Int {
        let watched = Set(try await watchesQuery(userID: userID).filter(\.$title.$id == titleID).all().compactMap(\.$episode.id))
        let toMark = episodes.filter { isAired($0) && !watched.contains($0.id!) }
        try await unhide(userID: userID, titleID: titleID)
        for episode in toMark {
            try await Watch(userID: userID, titleID: titleID, episodeID: episode.requireID(), watchedOn: nil,
                            service: service, origin: .manual).save(on: db)
        }
        if !toMark.isEmpty {
            try await WatchLaterService(db: db).removeAfterWatch(userID: userID, titleID: titleID, day: nil, origin: .manual)
        }
        return toMark.count
    }

    /// „… erneut gesehen“: one more undated watch for every aired episode that is behind the current round – the
    /// highest watch count among them, or the next round when all are level. Episodes watched again one by one
    /// („Erneut gesehen“) are therefore not counted twice when the round is finished with the button.
    ///
    /// Unhides the series; when anything was added, the title leaves the „Später ansehen“ (watch later) list.
    /// - Parameters:
    ///   - userID: The acting user.
    ///   - titleID: The series.
    ///   - episodes: The episodes of the round (a season or the whole series).
    ///   - service: The streaming service for the new watches, if any.
    /// - Returns: The number of watches added (0 when none of the episodes has aired).
    /// - Throws: Database errors.
    private func markRound(userID: UUID, titleID: UUID, episodes: [Episode], service: StreamingService?) async throws -> Int {
        let aired = episodes.filter(isAired)
        guard !aired.isEmpty else { return 0 }
        var counts: [UUID: Int] = [:]
        for watch in try await watchesQuery(userID: userID).filter(\.$title.$id == titleID).all() {
            if let episodeID = watch.$episode.id { counts[episodeID, default: 0] += 1 }
        }
        let current = aired.map { counts[$0.id!] ?? 0 }
        let highest = current.max() ?? 0
        let target = current.allSatisfy { $0 == highest } ? highest + 1 : highest
        let behind = aired.filter { (counts[$0.id!] ?? 0) < target }
        try await unhide(userID: userID, titleID: titleID)
        for episode in behind {
            try await Watch(userID: userID, titleID: titleID, episodeID: episode.requireID(), watchedOn: nil,
                            service: service, origin: .manual).save(on: db)
        }
        if !behind.isEmpty {
            try await WatchLaterService(db: db).removeAfterWatch(userID: userID, titleID: titleID, day: nil, origin: .manual)
        }
        return behind.count
    }
}

extension Request {
    /// The tracking service for this request; "today" comes from `AppConfig.today()`.
    var watches: WatchService { WatchService(db: db, today: application.appConfig.today) }
}
