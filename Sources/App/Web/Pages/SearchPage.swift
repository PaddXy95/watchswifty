import Elementary
import ElementaryHTMX2

struct SearchResultModel {
    let result: TMDBSearchResult
    let status: String?
    let rating: Int?
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
                      .hx.target("#results"))
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
                a(.class("card search-result"), .href("/\(item.result.kind.rawValue)/\(item.result.id)")) {
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
            }
        }
    }
}
