import Foundation

/// A lightweight, value-type snapshot of an episode, used by the progress calculations and view models.
struct EpisodeInfo: Sendable, Equatable {
    let id: UUID
    let season: Int
    let number: Int
    let name: String
    let airDate: String?
    var overview: String?
    /// Minutes; nil or 0 = unknown.
    var runtime: Int?

    /// Creates an episode snapshot from its parts.
    /// - Parameters:
    ///   - id: The episode's ID.
    ///   - season: The season number (0 = specials).
    ///   - number: The episode number within the season.
    ///   - name: The episode name.
    ///   - airDate: The air date (`YYYY-MM-DD`), or nil when unknown.
    ///   - overview: The TMDB overview, if loaded.
    ///   - runtime: The runtime in minutes, if known.
    init(id: UUID, season: Int, number: Int, name: String, airDate: String?, overview: String? = nil, runtime: Int? = nil) {
        self.id = id
        self.season = season
        self.number = number
        self.name = name
        self.airDate = airDate
        self.overview = overview
        self.runtime = runtime
    }

    /// Creates a snapshot of a stored episode.
    /// - Parameter episode: A saved episode (its ID must be set).
    init(_ episode: Episode) {
        self.init(id: episode.id!, season: episode.season, number: episode.number, name: episode.name, airDate: episode.airDate,
                  overview: episode.overview, runtime: episode.runtime)
    }

    /// The episode code, e.g. `S01E05`.
    var code: String { String(format: "S%02dE%02d", season, number) }

    /// Whether the episode has aired by `today`; episodes without an air date count as not aired.
    /// - Parameter today: The current day (`YYYY-MM-DD`, see `AppConfig.today()`).
    /// - Returns: True when the air date is on or before `today`.
    func isAired(today: String) -> Bool {
        guard let airDate else { return false }
        return airDate <= today
    }
}

/// The episodes watched in the current round: those watched more often than the aired regular episode watched least.
///
/// While an aired regular episode is still unwatched that is every watched episode (the first round). Once all of them
/// are watched, watching some again („Erneut gesehen“) starts a new round, and only those count, so the series is
/// continued like one watched for the first time. Empty when every round is complete.
/// - Parameters:
///   - episodes: All episodes of the series, in any order.
///   - watchCounts: The number of the user's watches per episode ID; missing = unwatched.
///   - today: The current day (`YYYY-MM-DD`).
/// - Returns: IDs of the episodes watched in the current round, to pass as `watched` to ``nextEpisode(in:watched:today:)``.
func currentRound(in episodes: [EpisodeInfo], watchCounts: [UUID: Int], today: String) -> Set<UUID> {
    let completed = episodes.filter { $0.season >= 1 && $0.isAired(today: today) }.map { watchCounts[$0.id] ?? 0 }.min() ?? 0
    return Set(watchCounts.filter { $0.value > completed }.keys)
}

/// The first aired, unwatched regular episode after the highest watched regular episode
/// (specials and gaps before the highest watched episode are ignored). Nil = nothing watched or caught up.
/// - Parameters:
///   - episodes: All episodes of the series, in any order.
///   - watched: IDs of the episodes the user has watched.
///   - today: The current day (`YYYY-MM-DD`).
/// - Returns: The next episode to watch, or nil.
func nextEpisode(in episodes: [EpisodeInfo], watched: Set<UUID>, today: String) -> EpisodeInfo? {
    let regular = episodes.filter { $0.season >= 1 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    guard let highest = regular.lastIndex(where: { watched.contains($0.id) }) else { return nil }
    return regular[(highest + 1)...].first { !watched.contains($0.id) && $0.isAired(today: today) }
}

/// Aired, unwatched regular episodes from `next` onwards (including `next`).
/// - Parameters:
///   - episodes: All episodes of the series, in any order.
///   - next: The first episode to count, usually the result of ``nextEpisode(in:watched:today:)``.
///   - watched: IDs of the episodes the user has watched.
///   - today: The current day (`YYYY-MM-DD`).
/// - Returns: The number of episodes still to watch.
func remainingAiredCount(in episodes: [EpisodeInfo], from next: EpisodeInfo, watched: Set<UUID>, today: String) -> Int {
    episodes.filter { e in
        e.season >= 1 && (e.season, e.number) >= (next.season, next.number) && !watched.contains(e.id) && e.isAired(today: today)
    }.count
}
