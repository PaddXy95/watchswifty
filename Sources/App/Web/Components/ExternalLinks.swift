import Elementary
import Foundation

/// Links to TMDB, IMDb, Rotten Tomatoes and (series only) SeriesGraph, opened in a new tab.
struct ExternalLinks: HTML {
    let title: Title

    private func encoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private var links: [(String, String)] {
        let kind = title.titleKind == .tv ? "tv" : "movie"
        var result = [("TMDB", "https://www.themoviedb.org/\(kind)/\(title.tmdbID)")]
        if let imdb = title.imdbID, !imdb.isEmpty {
            result.append(("IMDb", "https://www.imdb.com/title/\(imdb)/"))
        } else {
            result.append(("IMDb", "https://www.imdb.com/find/?q=\(encoded(title.name))"))
        }
        result.append(("Rotten Tomatoes", "https://www.rottentomatoes.com/search?search=\(encoded(title.name))"))
        if title.titleKind == .tv {
            result.append(("SeriesGraph", "https://seriesgraph.com/show/\(title.tmdbID)"))
        }
        return result
    }

    var body: some HTML {
        p(.class("external-links")) {
            for (index, link) in links.enumerated() {
                if index > 0 { " · " }
                a(.href(link.1), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { link.0 }
            }
        }
    }
}
