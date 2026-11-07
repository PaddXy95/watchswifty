import Foundation

struct EpisodeCandidate: Sendable, Equatable {
    let id: UUID
    let season: Int
    let number: Int
    let name: String
}

/// Matches a Netflix episode title to TMDB episodes. Returns [] when nothing matches or the
/// match is ambiguous (better unmatched than wrong); two IDs for a merged double episode.
func matchEpisodes(title: String, season: Int?, in candidates: [EpisodeCandidate]) -> [UUID] {
    let pool = season.map { s in candidates.filter { $0.season == s } } ?? candidates.filter { $0.season >= 1 }
    guard !pool.isEmpty else { return [] }

    // 1. "Folge N" → episode number N when the season is unambiguous.
    if let match = title.firstMatch(of: /^Folge (\d+)$/), let number = Int(match.1),
       season != nil || Set(pool.map(\.season)).count == 1 {
        return pool.first { $0.number == number }.map { [$0.id] } ?? []
    }

    let wanted = normalizeTitle(title)
    // 2. Exactly one equal normalized name.
    let exact = pool.filter { normalizeTitle($0.name) == wanted }
    if exact.count == 1 { return [exact[0].id] }

    // 3. Merged double episode "… – Teil 1 und 2".
    if let match = title.firstMatch(of: /^(.*?)[\s–:-]*Teil 1 und 2$/) {
        let base = normalizeTitle(String(match.1))
        let parts = pool.filter { !base.isEmpty && normalizeTitle($0.name).hasPrefix(base) }
        if parts.count == 2 { return parts.sorted { $0.number < $1.number }.map(\.id) }
    }

    // 4. Fuzzy: clear winner with similarity ≥ 0.85. Titles whose numbers differ ("Die 7 Leben" vs
    //    "Die 8 Leben") are never fuzzy matches.
    let wantedNumbers = numberTokens(wanted)
    let scored = pool.filter { numberTokens(normalizeTitle($0.name)) == wantedNumbers }
        .map { (candidate: $0, score: similarity(wanted, normalizeTitle($0.name))) }.sorted { $0.score > $1.score }
    guard let best = scored.first, best.score >= 0.85 else { return [] }
    if scored.count > 1, scored[1].score >= best.score - 0.10 { return [] }
    return [best.candidate.id]
}

/// Digit runs in a (normalized) title, in order.
func numberTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { !$0.isNumber }).map(String.init)
}
