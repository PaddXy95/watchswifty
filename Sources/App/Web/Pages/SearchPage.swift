import Elementary
import ElementaryHTMX2

/// One search hit with what the user already has: tracking status, rating and whether it is on „Später ansehen“.
struct SearchResultModel {
    let result: TMDBSearchResult
    /// Status badge such as „3/10 gesehen“ (3/10 watched) or „gesehen“ (watched); nil when untracked.
    let status: String?
    /// The user's rating (1–10), nil when unrated.
    let rating: Int?
    /// The title is on the user's „Später ansehen“ list.
    var watchLater = false
}

/// „Suche“ (search) page at `/search`: the search field and the results for the initial query.
///
/// Typing updates the results live: the field requests `GET /search/results` 300 ms after the last input and swaps
/// `#results` (outerHTML).
struct SearchPage: HTML {
    let nav: NavContext
    /// The query from `?q=`, prefilled in the field.
    let query: String
    /// The user has a TMDB token; without one the results show `TokenHint`.
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

/// Notice that searching needs the user's own TMDB token, linking to „Konto“ (account).
struct TokenHint: HTML {
    var body: some HTML {
        p(.class("notice")) {
            "Für die Suche brauchst du einen eigenen TMDB-Token. Hinterlege ihn unter "
            a(.href("/account")) { "Konto" }
            "."
        }
    }
}

/// The `#results` card list of search hits; also returned alone by `GET /search/results` to replace itself.
///
/// Links to the title pages are boosted and show a loading indicator on their card; each card has a
/// `SearchWatchLaterButton`.
struct SearchResults: HTML {
    let results: [SearchResultModel]
    /// False shows `TokenHint` above the (empty) list.
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
    /// Series or movie.
    let kind: TitleKind
    /// TMDB ID of the title.
    let tmdbID: Int
    /// Already on the list: shows the „✓ Später“ marker instead of the button. The add request returns this view with
    /// `onList` set, swapped in as outerHTML.
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
