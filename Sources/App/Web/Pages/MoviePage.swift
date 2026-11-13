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
                Poster(path: title.posterPath, alt: title.name, displayWidth: 140)
                div {
                    h1 {
                        title.name
                        if let year = title.year { span(.class("muted")) { " (\(year))" } }
                    }
                    let meta = [title.runtime.flatMap { $0 > 0 ? formatDuration(minutes: $0) : nil }].compactMap { $0 }
                        + (title.genreList ?? []).map(\.label)
                    if !meta.isEmpty {
                        p(.class("muted title-meta")) { meta.joined(separator: " · ") }
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
                WatchList(watches: watches, deletePrefix: "/movie/\(tmdbID)/watches", target: "#movie-watches")
            }
            WatchForm(action: "/movie/\(tmdbID)/watch", target: "#movie-watches",
                      submitLabel: watches.isEmpty ? "Gesehen" : "Erneut gesehen", rewatch: !watches.isEmpty,
                      today: today, defaultService: watches.first?.streamingService)
        }
    }
}
