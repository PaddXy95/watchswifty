import Elementary

struct SeriesPage: HTML {
    let nav: NavContext
    let title: Title
    let seasons: [SeasonModel]
    let rating: Int?
    let hidden: Bool
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
                    RatingControl(kind: .tv, tmdbID: title.tmdbID, rating: rating)
                    HiddenToggle(tmdbID: title.tmdbID, hidden: hidden)
                }
            }
            if seasons.isEmpty {
                p(.class("muted")) { "Für diese Serie sind keine Folgen bekannt." }
            }
            SeasonsList(tmdbID: title.tmdbID, seasons: seasons, today: today, defaultService: defaultService)
        }
    }
}
