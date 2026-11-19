import Foundation

enum TitleChoice: Equatable {
    case match(TMDBSearchResult)
    case review([TMDBSearchResult])
    case notFound
}

/// Distance between two years that never traps, also for entries stored before years were range-checked.
private func yearGap(_ a: Int, _ b: Int) -> Int {
    let (difference, overflow) = a.subtractingReportingOverflow(b)
    return overflow || difference == .min ? .max : abs(difference)
}

/// Picks the TMDB title for an import entry: an exact title among results within ±1 year of the given year, or the
/// only result in that range, is taken automatically; anything else goes to review (at most 5 candidates).
func chooseTitle(query: String, year: Int?, results: [TMDBSearchResult]) -> TitleChoice {
    guard !results.isEmpty else { return .notFound }
    let wanted = normalizeTitle(query)
    func isExact(_ result: TMDBSearchResult) -> Bool {
        normalizeTitle(result.name) == wanted || result.originalName.map(normalizeTitle) == wanted
    }
    let inRange = year.map { year in
        results.filter { result in result.year.map { yearGap($0, year) <= 1 } ?? false }
            .sorted { yearGap($0.year ?? 0, year) < yearGap($1.year ?? 0, year) }
    } ?? results
    let exact = inRange.filter(isExact)
    func distance(_ result: TMDBSearchResult) -> Int { year.map { yearGap(result.year ?? 0, $0) } ?? 0 }
    // Several exact titles: the one closest to the given year wins, unless two are equally close.
    if exact.count == 1 || (exact.count > 1 && year != nil && distance(exact[0]) < distance(exact[1])) { return .match(exact[0]) }
    if inRange.count == 1 { return .match(inRange[0]) }
    return .review(Array((inRange.isEmpty ? results : inRange).prefix(5)))
}

/// Whether a title found by `tmdb_id` or `imdb_id` plausibly is the one the file means: same normalized title (or
/// original title), or a year within ±1, or no year in the file. Guards against wrong IDs and swapped types.
func plausibleIDMatch(title: String, year: Int?, found: TMDBSearchResult) -> Bool {
    let wanted = normalizeTitle(title)
    if normalizeTitle(found.name) == wanted || found.originalName.map(normalizeTitle) == wanted { return true }
    guard let year else { return true }
    return found.year.map { yearGap($0, year) <= 1 } ?? false
}
