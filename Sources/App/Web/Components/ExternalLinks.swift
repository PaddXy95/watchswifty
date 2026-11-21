import Elementary
import Foundation

/// TMDB, IMDb, Rotten Tomatoes and (series only) SeriesGraph links of a title (web page and API).
///
/// Without an IMDb ID the IMDb link is a name search; Rotten Tomatoes is always a name search.
/// - Parameter title: The cached title.
/// - Returns: (label, URL) pairs in display order.
func externalLinks(for title: Title) -> [(label: String, url: String)] {
    /// Percent-encodes `text` for a query value, keeping only alphanumerics and `-._~`.
    /// - Parameter text: The text to encode.
    /// - Returns: The encoded text, or `text` unchanged if encoding fails.
    func encoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
    let kind = title.titleKind == .tv ? "tv" : "movie"
    var result = [(label: "TMDB", url: "https://www.themoviedb.org/\(kind)/\(title.tmdbID)")]
    if let imdb = title.imdbID, !imdb.isEmpty {
        result.append((label: "IMDb", url: "https://www.imdb.com/title/\(imdb)/"))
    } else {
        result.append((label: "IMDb", url: "https://www.imdb.com/find/?q=\(encoded(title.name))"))
    }
    result.append((label: "Rotten Tomatoes", url: "https://www.rottentomatoes.com/search?search=\(encoded(title.name))"))
    if title.titleKind == .tv {
        result.append((label: "SeriesGraph", url: "https://seriesgraph.com/show/\(title.tmdbID)"))
    }
    return result
}

/// Links to TMDB, IMDb, Rotten Tomatoes and (series only) SeriesGraph, opened in a new tab.
struct ExternalLinks: HTML {
    /// The title whose links are shown.
    let title: Title

    /// The links of ``externalLinks(for:)`` as (label, URL) pairs.
    private var links: [(String, String)] { externalLinks(for: title).map { ($0.label, $0.url) } }

    var body: some HTML {
        p(.class("external-links")) {
            for (index, link) in links.enumerated() {
                if index > 0 { " · " }
                a(.href(link.1), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { link.0 }
            }
        }
    }
}
