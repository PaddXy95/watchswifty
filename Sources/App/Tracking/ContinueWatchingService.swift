import Fluent
import Foundation
import Vapor

struct ContinueCard: Sendable {
    let titleID: UUID
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let rating: Int?
    let next: EpisodeInfo
    let remaining: Int
    let lastWatchedOn: String?
    let lastService: StreamingService?
    /// Service for the card's button: the most recently used one that has a link (see `watchLink(for:)`).
    let watchService: StreamingService?
    /// Newest dated watch, else the day the newest (undated) watch was recorded.
    var lastActivityOn: String = ""
}

/// Builds the "Weiterschauen" shelf for one user (§5.2).
struct ContinueWatchingService {
    let db: any Database

    /// Later of the newest dated watch and the day the newest undated (bulk-marked) watch was made,
    /// so catching up after an old import keeps the series on the shelf.
    static func lastActivity(_ watches: [Watch]) -> String? {
        let dated = watches.compactMap(\.watchedOn).max()
        let undatedDay = watches.filter { $0.watchedOn == nil }.compactMap(\.createdAt).max().map { CalendarDay.today(now: $0) }
        return [dated, undatedDay].compactMap { $0 }.max()
    }

    func cards(userID: UUID, today: String) async throws -> [ContinueCard] {
        try await build(userID: userID, onlyTitle: nil, today: today)
    }

    func card(userID: UUID, titleID: UUID, today: String) async throws -> ContinueCard? {
        try await build(userID: userID, onlyTitle: titleID, today: today).first
    }

    private func build(userID: UUID, onlyTitle: UUID?, today: String) async throws -> [ContinueCard] {
        var watchQuery = Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$episode.$id != nil)
        if let onlyTitle { watchQuery = watchQuery.filter(\.$title.$id == onlyTitle) }
        let watches = try await watchQuery.all()
        let watchesByTitle = Dictionary(grouping: watches, by: { $0.$title.id })
        let titleIDs = Array(watchesByTitle.keys)
        guard !titleIDs.isEmpty else { return [] }

        let titles = try await Title.query(on: db).filter(\.$id ~~ titleIDs).filter(\.$kind == TitleKind.tv.rawValue).all()
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })
        let episodes = try await Episode.query(on: db).filter(\.$title.$id ~~ titleIDs).all()
        let episodesByTitle = Dictionary(grouping: episodes.map { ($0.$title.id, EpisodeInfo($0)) }, by: { $0.0 }).mapValues { $0.map(\.1) }

        var result: [(card: ContinueCard, sortKey: (Int, String, Date))] = []
        for title in titles {
            let titleID = try title.requireID()
            if entryByTitle[titleID]?.hidden == true { continue }
            let titleWatches = watchesByTitle[titleID] ?? []
            let watched = Set(titleWatches.compactMap(\.$episode.id))
            let titleEpisodes = episodesByTitle[titleID] ?? []
            guard let next = nextEpisode(in: titleEpisodes, watched: watched, today: today) else { continue }

            let lastDated = titleWatches.compactMap(\.watchedOn).max()
            let latestCreated = titleWatches.compactMap(\.createdAt).max() ?? .distantPast
            let byRecency = titleWatches.sorted { a, b in
                switch (a.watchedOn, b.watchedOn) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
                }
            }
            let card = ContinueCard(
                titleID: titleID, tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath,
                rating: entryByTitle[titleID]?.rating, next: next,
                remaining: remainingAiredCount(in: titleEpisodes, from: next, watched: watched, today: today),
                lastWatchedOn: lastDated,
                lastService: byRecency.lazy.compactMap(\.streamingService).first,
                watchService: byRecency.lazy.compactMap(\.streamingService).first { $0.watchLink(for: title.name) != nil }
                    ?? (titleWatches.contains { $0.watchOrigin == .import } ? .netflix : nil),
                lastActivityOn: Self.lastActivity(titleWatches) ?? lastDated ?? CalendarDay.today(now: latestCreated)
            )
            // Dated series first (newest day first), then undated-only series by creation time.
            result.append((card, (lastDated == nil ? 1 : 0, lastDated ?? "", latestCreated)))
        }
        return result.sorted { a, b in
            if a.sortKey.0 != b.sortKey.0 { return a.sortKey.0 < b.sortKey.0 }
            if a.sortKey.1 != b.sortKey.1 { return a.sortKey.1 > b.sortKey.1 }
            return a.sortKey.2 > b.sortKey.2
        }.map(\.card)
    }
}
