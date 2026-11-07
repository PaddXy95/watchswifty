import Elementary
import ElementaryHTMX2

struct SeriesPage: HTML {
    let nav: NavContext
    let title: Title
    let seasons: [SeasonModel]
    let rating: Int?
    let comment: String?
    let hidden: Bool
    var followed = false
    let today: String
    let defaultService: StreamingService?

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
                    RatingControl(kind: .tv, tmdbID: title.tmdbID, rating: rating)
                    div(.class("title-actions")) {
                        FollowToggle(tmdbID: title.tmdbID, followed: followed)
                        HiddenToggle(tmdbID: title.tmdbID, hidden: hidden)
                    }
                    CommentBox(id: "series-comment", action: "/tv/\(title.tmdbID)/comment", caption: "Kommentar zur Serie", comment: comment)
                }
            }
            if seasons.isEmpty {
                p(.class("muted")) { "Für diese Serie sind keine Folgen bekannt." }
            } else {
                button(.class("series-action"), .hx.post("/tv/\(title.tmdbID)/watch-all"),
                       .hx.confirm("Alle erschienenen Folgen als gesehen markieren?"),
                       .hx.target("#seasons"), .hx.swap(.outerHTMLGuarded)) { "Gesamte Serie gesehen" }
            }
            SeasonsList(tmdbID: title.tmdbID, seasons: seasons, today: today, defaultService: defaultService)
        }
    }
}
