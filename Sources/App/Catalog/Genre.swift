import Foundation

/// One genre list for series and movies (spec `2026-11-13-feedback-round-design.md` §7). TMDB keeps separate lists
/// with mixed series genres („Action & Adventure“); those are split, so a filter or statistic counts both kinds alike.
/// Raw values are stable keys (stored in `titles.genres`, sent by the App API); labels are German.
enum Genre: String, CaseIterable, Sendable {
    case action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, music,
         mystery, romance, scienceFiction = "science_fiction", tvMovie = "tv_movie", thriller, war, western,
         kids, news, reality, soap, talk, politics

    var label: String {
        switch self {
        case .action: "Action"
        case .adventure: "Abenteuer"
        case .animation: "Animation"
        case .comedy: "Komödie"
        case .crime: "Krimi"
        case .documentary: "Dokumentation"
        case .drama: "Drama"
        case .family: "Familie"
        case .fantasy: "Fantasy"
        case .history: "Historie"
        case .horror: "Horror"
        case .music: "Musik"
        case .mystery: "Mystery"
        case .romance: "Liebesfilm"
        case .scienceFiction: "Science-Fiction"
        case .tvMovie: "TV-Film"
        case .thriller: "Thriller"
        case .war: "Krieg"
        case .western: "Western"
        case .kids: "Kinder"
        case .news: "Nachrichten"
        case .reality: "Reality"
        case .soap: "Soap"
        case .talk: "Talk"
        case .politics: "Politik"
        }
    }

    /// TMDB genre ids of both lists (movie and TV); the mixed TV genres map to two of ours.
    private static let byTMDBID: [Int: [Genre]] = [
        28: [.action], 12: [.adventure], 16: [.animation], 35: [.comedy], 80: [.crime], 99: [.documentary],
        18: [.drama], 10751: [.family], 14: [.fantasy], 36: [.history], 27: [.horror], 10402: [.music],
        9648: [.mystery], 10749: [.romance], 878: [.scienceFiction], 10770: [.tvMovie], 53: [.thriller],
        10752: [.war], 37: [.western], 10762: [.kids], 10763: [.news], 10764: [.reality], 10766: [.soap],
        10767: [.talk],
        10759: [.action, .adventure], 10765: [.scienceFiction, .fantasy], 10768: [.war, .politics],
    ]

    /// Our genres for TMDB ids, in order of first appearance, without duplicates; unknown ids are ignored.
    static func from(tmdbIDs: [Int]) -> [Genre] {
        var result: [Genre] = []
        for genre in tmdbIDs.flatMap({ byTMDBID[$0] ?? [] }) where !result.contains(genre) {
            result.append(genre)
        }
        return result
    }

    private static let collation = Locale(identifier: "de_DE")

    static func sortedByLabel(_ genres: some Sequence<Genre>) -> [Genre] {
        genres.sorted { $0.label.compare($1.label, locale: collation) == .orderedAscending }
    }
}

extension Genre {
    /// A stored `genres` column as a list: nil = not fetched yet, [] = TMDB has none. Unknown keys are skipped.
    static func list(_ stored: String?) -> [Genre]? {
        stored.map { $0.split(separator: ",").compactMap { Genre(rawValue: String($0)) } }
    }
}

extension Title {
    /// `genres` as a list: nil = not fetched yet, [] = TMDB has none. Unknown keys are skipped.
    var genreList: [Genre]? {
        get { Genre.list(genres) }
        set { genres = newValue?.map(\.rawValue).joined(separator: ",") }
    }
}
