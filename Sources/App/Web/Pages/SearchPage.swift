import Elementary
import ElementaryHTMX2

struct SearchResultModel {
    let result: TMDBSearchResult
    let status: String?
    let rating: Int?
    var watchLater = false
}

struct SearchPage: HTML {
    let nav: NavContext
    let query: String
    let hasToken: Bool
    let results: [SearchResultModel]

    var body: some HTML {
        PageLayout(title: "Suche", nav: nav) {
            h1 { "Suche" }
            form(.method(.get), .action("/search"), .class("search-form")) {
                input(.type(.search), .name("q"), .value(query), .autofocus,
                      .custom(name: "placeholder", value: "Serie oder Film"),
                      .custom(name: "aria-label", value: "Serie oder Film suchen"),
                      .hx.get("/search/results"), .custom(name: "hx-trigger", value: "input changed delay:300ms, search"),
                      .hx.target("#results"), .hx.swap(.outerHTML))
            }
            SearchResults(results: results, hasToken: hasToken)
        }
    }
}

struct TokenHint: HTML {
    var body: some HTML {
        p(.class("notice")) {
            "Für die Suche brauchst du einen eigenen TMDB-Token. Hinterlege ihn unter "
            a(.href("/account")) { "Konto" }
            "."
        }
    }
}

struct SearchResults: HTML {
    let results: [SearchResultModel]
    var hasToken = true

    var body: some HTML {
        div(.id("results"), .class("card-list"), .hx.boost(true)) {
            if !hasToken { TokenHint() }
            for item in results {
                div(.class("card search-result")) {
                    a(.class("search-link"), .href("/\(item.result.kind.rawValue)/\(item.result.id)"),
                      .custom(name: "hx-indicator", value: "closest .search-result, #page-loader")) {
                        Poster(path: item.result.posterPath, alt: item.result.name)
                        div {
                            strong { item.result.name }
                            if let year = item.result.year { span(.class("muted")) { " (\(year))" } }
                            div {
                                span(.class("badge")) { item.result.kind == .tv ? "Serie" : "Film" }
                                if let status = item.status { " "; span(.class("badge")) { status } }
                                if let rating = item.rating { " "; span(.class("rating")) { "★ \(rating)" } }
                            }
                        }
                    }
                    SearchWatchLaterButton(kind: item.result.kind, tmdbID: item.result.id, onList: item.watchLater)
                }
            }
        }
    }
}

/// „+ Später“ on a search result; adds the title to „Später ansehen“ (a second click does nothing more).
struct SearchWatchLaterButton: HTML {
    let kind: TitleKind
    let tmdbID: Int
    let onList: Bool

    var body: some HTML {
        if onList {
            span(.class("watch-later-add done"), .custom(name: "title", value: "Steht auf „Später ansehen“")) { "✓ Später" }
        } else {
            button(.class("watch-later-add"), .hx.post("/watch-later"), .hx.vals(#"{"kind":"\#(kind.rawValue)","tmdbID":"\#(tmdbID)"}"#),
                   .hx.swap(.outerHTML), .custom(name: "aria-label", value: "Zu „Später ansehen“ hinzufügen")) { "+ Später" }
        }
    }
}
