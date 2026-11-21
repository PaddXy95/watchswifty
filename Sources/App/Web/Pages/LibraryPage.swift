import Elementary
import ElementaryHTMX2

/// One poster of the library grid: the title with the user's rating and hidden flag.
struct LibraryItem {
    let title: Title
    let rating: Int?
    let hidden: Bool
}

/// „Bibliothek“ (library) page at `/library`: kind filter and sort links, the genre select and the poster grid.
///
/// Changing the genre submits via htmx (`GET /library`), swaps `main` and pushes the new URL, like a filter link. Poster
/// links are boosted and show a loading indicator on their item. Hidden titles carry a `HiddenToggle` to show them
/// again.
struct LibraryPage: HTML {
    let navContext: NavContext
    let items: [LibraryItem]
    /// Active kind filter: `all`, `tv`, `movie` or `hidden`.
    let filter: String
    /// Active sort order: `recent`, `rating` or `name`.
    let sort: String
    /// Active genre filter, nil for all genres.
    var genre: Genre? = nil
    /// Genres of the user's library (choices of the genre filter).
    var genres: [Genre] = []

    /// Kind filters as (query value, German label).
    private let filters = [("all", "Alle"), ("tv", "Serien"), ("movie", "Filme"), ("hidden", "Ausgeblendet")]
    /// Sort orders as (query value, German label).
    private let sorts = [("recent", "Zuletzt gesehen"), ("rating", "Bewertung"), ("name", "Name")]

    /// The library's genres plus the active one, so a filter from an old link stays visible and can be cleared.
    private var choices: [Genre] {
        guard let genre, !genres.contains(genre) else { return genres }
        return Genre.sortedByLabel(genres + [genre])
    }

    /// Library URL for a filter and sort order, keeping the active genre.
    /// - Parameters:
    ///   - filter: Kind filter value.
    ///   - sort: Sort order value.
    /// - Returns: The `/library?…` URL.
    private func href(filter: String, sort: String) -> String {
        "/library?filter=\(filter)&sort=\(sort)" + (genre.map { "&genre=\($0.rawValue)" } ?? "")
    }

    var body: some HTML {
        PageLayout(title: "Bibliothek", nav: navContext) {
            SectionTabs.library(.titles)
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
