import Foundation

struct EpisodeInfo: Sendable, Equatable {
    let id: UUID
    let season: Int
    let number: Int
    let name: String
    let airDate: String?

    init(id: UUID, season: Int, number: Int, name: String, airDate: String?) {
        self.id = id
        self.season = season
        self.number = number
        self.name = name
        self.airDate = airDate
    }

    init(_ episode: Episode) {
        self.init(id: episode.id!, season: episode.season, number: episode.number, name: episode.name, airDate: episode.airDate)
    }

    var code: String { String(format: "S%02dE%02d", season, number) }

    func isAired(today: String) -> Bool {
        guard let airDate else { return false }
        return airDate <= today
    }
}

/// The first aired, unwatched regular episode after the highest watched regular episode
/// (specials and gaps before the highest watched episode are ignored). Nil = nothing watched or caught up.
func nextEpisode(in episodes: [EpisodeInfo], watched: Set<UUID>, today: String) -> EpisodeInfo? {
    let regular = episodes.filter { $0.season >= 1 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    guard let highest = regular.lastIndex(where: { watched.contains($0.id) }) else { return nil }
    return regular[(highest + 1)...].first { !watched.contains($0.id) && $0.isAired(today: today) }
}

/// Aired, unwatched regular episodes from `next` onwards (including `next`).
func remainingAiredCount(in episodes: [EpisodeInfo], from next: EpisodeInfo, watched: Set<UUID>, today: String) -> Int {
    episodes.filter { e in
        e.season >= 1 && (e.season, e.number) >= (next.season, next.number) && !watched.contains(e.id) && e.isAired(today: today)
    }.count
}
