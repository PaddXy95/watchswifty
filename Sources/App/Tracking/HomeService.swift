import Fluent
import Foundation
import Vapor

/// The start page (web) and `GET /v1/continue-watching` / `GET /v1/notes` (API).
struct HomeService {
    let db: any Database
    let watches: WatchService

    /// Series inactive for longer than this are hidden unless all are requested.
    static let cutoffMonths = 3

    /// The continue-watching cards, without those inactive for longer than ``cutoffMonths`` unless `showAll` is set.
    /// - Parameters:
    ///   - userID: The user.
    ///   - today: The current day (`YYYY-MM-DD`, see `AppConfig.today()`).
    ///   - showAll: When true, older cards are kept too.
    /// - Returns: The visible cards and how many were left out.
    /// - Throws: Database errors.
    func shelf(userID: UUID, today: String, showAll: Bool) async throws -> (cards: [ContinueCard], olderCount: Int) {
        let cards = try await ContinueWatchingService(db: db).cards(userID: userID, today: today)
        let cutoff = CalendarDay.adding(months: -Self.cutoffMonths, to: today)
        let visible = showAll ? cards : cards.filter { $0.lastActivityOn >= cutoff }
        return (visible, cards.count - visible.count)
    }

    /// The „Neue Folgen“ (new episodes) and „Demnächst“ (upcoming) notes for the user's followed series.
    /// - Parameters:
    ///   - userID: The user.
    ///   - today: The current day (`YYYY-MM-DD`).
    /// - Returns: The new-episode notes and the upcoming notes for the next 14 days.
    /// - Throws: Database errors.
    func notes(userID: UUID, today: String) async throws -> (newEpisodes: [NewEpisodesNote], upcoming: [UpcomingNote]) {
        let reminders = NewEpisodesService(db: db)
        return (try await reminders.notes(userID: userID, today: today), try await reminders.upcoming(userID: userID, today: today))
    }

    /// Marks the card's next episode (today, last used service) and returns the updated card, or nil when caught up.
    /// When the caller names the episode it saw and that is no longer the next one (double tap, second tab), nothing is marked.
    /// - Parameters:
    ///   - userID: The user.
    ///   - title: The series.
    ///   - expectedEpisodeID: The episode the caller saw as next, or nil to mark whatever is next now.
    ///   - today: The day to date the watch with (`YYYY-MM-DD`).
    /// - Returns: The card after marking, or nil when the series has no next episode.
    /// - Throws: `TrackingError` from ``WatchService/markEpisode(userID:episodeID:day:service:rewatch:)``, database errors.
    func markNext(userID: UUID, title: Title, expectedEpisodeID: UUID?, today: String) async throws -> ContinueCard? {
        let service = ContinueWatchingService(db: db)
        let titleID = try title.requireID()
        guard let card = try await service.card(userID: userID, titleID: titleID, today: today) else { return nil }
        if expectedEpisodeID == nil || expectedEpisodeID == card.next.id {
            _ = try await watches.markEpisode(userID: userID, episodeID: card.next.id, day: today,
                                              service: try await watches.lastService(userID: userID, titleID: titleID))
        }
        return try await service.card(userID: userID, titleID: titleID, today: today)
    }
}

extension Request {
    /// The start page service for this request.
    var home: HomeService { HomeService(db: db, watches: watches) }
}
