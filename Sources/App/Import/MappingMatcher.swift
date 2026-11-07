/// The single result whose (original) name equals the candidate after normalization; nil if none or several.
func autoMatch(candidate: String, in results: [TMDBSearchResult]) -> TMDBSearchResult? {
    let wanted = normalizeTitle(candidate)
    guard !wanted.isEmpty else { return nil }
    let hits = results.filter { result in
        normalizeTitle(result.name) == wanted || result.originalName.map(normalizeTitle) == wanted
    }
    return hits.count == 1 ? hits[0] : nil
}
