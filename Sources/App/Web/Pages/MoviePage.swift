import Elementary
import ElementaryHTMX2

struct MoviePage: HTML {
    let nav: NavContext
    let title: Title
    let watches: [Watch]
    let rating: Int?
    let comment: String?
    let today: String

    var body: some HTML {
        PageLayout(title: title.name, nav: nav) {
            div(.class("title-header")) {
                Poster(path: title.posterPath, alt: title.name)
                div {
                    h1 {
                        title.name
                        if let year = title.year { span(.class("muted")) { " (\(year))" } }
                    }
                    if let overview = title.overview, !overview.isEmpty {
                        p(.class("overview")) { overview }
                    }
                    ExternalLinks(title: title)
                    RatingControl(kind: .movie, tmdbID: title.tmdbID, rating: rating)
                    CommentBox(id: "movie-comment", action: "/movie/\(title.tmdbID)/comment", caption: "Kommentar zum Film", comment: comment)
                }
            }
            MovieWatchesSection(tmdbID: title.tmdbID, watches: watches, today: today)
        }
    }
}

struct MovieWatchesSection: HTML {
    let tmdbID: Int
    let watches: [Watch]
    let today: String

    var body: some HTML {
        section(.id("movie-watches")) {
            h2 { "Gesehen" }
            if watches.isEmpty {
                p(.class("muted")) { "Noch nicht gesehen." }
            } else {
                ul {
                    for watch in watches {
                        li { watchSummary([watch]) }
                    }
                }
            }
            WatchForm(action: "/movie/\(tmdbID)/watch", target: "#movie-watches",
                      submitLabel: watches.isEmpty ? "Gesehen" : "Erneut gesehen", rewatch: !watches.isEmpty,
                      today: today, defaultService: watches.first?.streamingService)
            if !watches.isEmpty {
                button(.hx.delete("/movie/\(tmdbID)/watch"), .hx.confirm("Alle Sichtungen dieses Films löschen?"),
                       .hx.target("#movie-watches"), .hx.swap(.outerHTML)) { "Nicht gesehen" }
            }
        }
    }
}
