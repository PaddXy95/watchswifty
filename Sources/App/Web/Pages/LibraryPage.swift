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
    var genre: Genre? = nil
    /// Genres of the user's library (choices of the genre filter).
    var genres: [Genre] = []

    private let filters = [("all", "Alle"), ("tv", "Serien"), ("movie", "Filme"), ("hidden", "Ausgeblendet")]
    private let sorts = [("recent", "Zuletzt gesehen"), ("rating", "Bewertung"), ("name", "Name")]

    /// The library's genres plus the active one, so a filter from an old link stays visible and can be cleared.
    private var choices: [Genre] {
        guard let genre, !genres.contains(genre) else { return genres }
        return Genre.sortedByLabel(genres + [genre])
    }

    private func href(filter: String, sort: String) -> String {
        "/library?filter=\(filter)&sort=\(sort)" + (genre.map { "&genre=\($0.rawValue)" } ?? "")
    }

    var body: some HTML {
        PageLayout(title: "Bibliothek", nav: navContext) {
            h1 { "Bibliothek" }
            nav(.class("filter-bar"), .custom(name: "aria-label", value: "Filter")) {
                for (key, label) in filters {
                    a(.href(href(filter: key, sort: sort))) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: key == filter)
                }
                span(.class("muted")) { " · Sortierung: " }
                for (key, label) in sorts {
                    a(.href(href(filter: filter, sort: key))) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: key == sort)
                }
            }
            if !choices.isEmpty {
                // Reloads on change (htmx); `main` is swapped and the address updated, like a filter link.
                form(.method(.get), .action("/library"), .class("genre-filter"), .hx.get("/library"),
                     .custom(name: "hx-trigger", value: "change"), .hx.target("main"), .hx.select("main"), .hx.swap(.outerHTML),
                     .custom(name: "hx-push-url", value: "true")) {
                    input(.type(.hidden), .name("filter"), .value(filter))
                    input(.type(.hidden), .name("sort"), .value(sort))
                    label {
                        "Genre"
                        select(.name("genre")) {
                            option(.value("")) { "Alle Genres" }
                            for choice in choices {
                                option(.value(choice.rawValue)) { choice.label }.attributes(.selected, when: choice == genre)
                            }
                        }
                    }
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
