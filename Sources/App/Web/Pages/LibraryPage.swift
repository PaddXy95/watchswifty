import Elementary
import ElementaryHTMX2

struct LibraryItem {
    let title: Title
    let rating: Int?
    let hidden: Bool
}

struct LibraryPage: HTML {
    let navContext: NavContext
    let items: [LibraryItem]
    let filter: String
    let sort: String

    private let filters = [("all", "Alle"), ("tv", "Serien"), ("movie", "Filme"), ("hidden", "Ausgeblendet")]
    private let sorts = [("recent", "Zuletzt gesehen"), ("rating", "Bewertung"), ("name", "Name")]

    var body: some HTML {
        PageLayout(title: "Bibliothek", nav: navContext) {
            h1 { "Bibliothek" }
            nav(.class("filter-bar"), .custom(name: "aria-label", value: "Filter")) {
                for (key, label) in filters {
                    a(.href("/library?filter=\(key)&sort=\(sort)")) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: key == filter)
                }
                span(.class("muted")) { " · Sortierung: " }
                for (key, label) in sorts {
                    a(.href("/library?filter=\(filter)&sort=\(key)")) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: key == sort)
                }
            }
            if items.isEmpty {
                p(.class("muted")) { "Keine Titel." }
            }
            div(.class("poster-grid"), .hx.boost(true)) {
                for item in items {
                    div(.class("library-item")) {
                        a(.href("/\(item.title.kind)/\(item.title.tmdbID)"),
                          .custom(name: "hx-indicator", value: "closest .library-item, #page-loader")) {
                            Poster(path: item.title.posterPath, alt: item.title.name, displayWidth: 200)
                            div { item.title.name }
                        }
                        if let rating = item.rating { span(.class("rating")) { "★ \(rating)" } }
                        if item.hidden { HiddenToggle(tmdbID: item.title.tmdbID, hidden: true) }
                    }
                }
            }
        }
    }
}
