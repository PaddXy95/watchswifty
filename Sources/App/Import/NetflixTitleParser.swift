import Foundation

enum ParsedNetflixTitle: Sendable, Equatable, Codable {
    case episode(show: String, season: Int?, episodeTitle: String)
    case movie(title: String)
}

private let numberedMarkers: Set<String> = ["Staffel", "Season", "Teil", "Part", "Kapitel", "Ausgabe", "Buch", "Volume"]
private let unnumberedMarkers: Set<String> = ["Miniserie", "Limitierte Serie", "Limited Series"]

/// Returns nil when the segment is not a season marker, `.some(nil)` for an unnumbered marker
/// (miniseries), `.some(n)` for "Staffel n" and friends.
private func seasonMarker(_ segment: String) -> Int?? {
    if unnumberedMarkers.contains(segment) { return .some(nil) }
    let words = segment.split(separator: " ")
    if words.count == 2, numberedMarkers.contains(String(words[0])), let n = Int(words[1]) { return .some(n) }
    // "Ted – Staffel 1"
    if let range = segment.range(of: " – Staffel ", options: .backwards), range.lowerBound > segment.startIndex,
       let n = Int(segment[range.upperBound...]) {
        return .some(n)
    }
    return nil
}

/// Splits a Netflix history title into show / season / episode, or a movie.
/// The first season marker (not first or last segment) wins; without one, the last
/// segment is the episode title; a single segment is a movie.
func parseNetflixTitle(_ raw: String) -> ParsedNetflixTitle {
    let segments = raw.components(separatedBy: ": ")
    guard segments.count >= 2 else { return .movie(title: raw) }
    if segments.count >= 3 {
        for index in 1..<(segments.count - 1) {
            if let season = seasonMarker(segments[index]) {
                return .episode(show: segments[..<index].joined(separator: ": "), season: season,
                                episodeTitle: segments[(index + 1)...].joined(separator: ": "))
            }
        }
    }
    return .episode(show: segments.dropLast().joined(separator: ": "), season: nil, episodeTitle: segments.last!)
}
