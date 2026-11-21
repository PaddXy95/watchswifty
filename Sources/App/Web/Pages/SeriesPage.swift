import Elementary
import ElementaryHTMX2

/// Series detail page at `/tv/:tmdbID`.
///
/// The header holds poster, genres, overview, external links, rating, the „Später ansehen“ (watch later), follow and
/// hide toggles and the series comment. Below follow the streaming availability (when given), the form to mark the
/// whole series (only when episodes are known) and the season list.
struct SeriesPage: HTML {
    let nav: NavContext
    /// The cached series.
    let title: Title
    /// Seasons with their episodes and the user's viewings.
    let seasons: [SeasonModel]
    /// The user's rating (1–10), nil when unrated.
    let rating: Int?
    /// The user's comment on the series.
    let comment: String?
    /// The user has hidden the series (`HiddenToggle`).
    let hidden: Bool
    /// The user follows the series (notices about new episodes).
    var followed = false
    /// Today (`YYYY-MM-DD`) for date defaults and the aired check.
    let today: String
    /// Streaming service preselected in the watch forms.
    let defaultService: StreamingService?
    /// The series is on the user's „Später ansehen“ list.
    var watchLater = false
    /// Streaming availability block; nil leaves it out.
    var availability: AvailabilityView? = nil

    var body: some HTML {
        PageLayout(title: title.name, nav: nav) {
            div(.class("title-header")) {
                Poster(path: title.posterPath, alt: title.name, displayWidth: 140)
                div {
                    h1 {
                        title.name
                        if let year = title.year { span(.class("muted")) { " (\(year))" } }
                    }
                    if let genres = title.genreList, !genres.isEmpty {
                        p(.class("muted title-meta")) { genres.map(\.label).joined(separator: " · ") }
                    }
                    if let overview = title.overview, !overview.isEmpty {
                        p(.class("overview")) { overview }
                    }
                    ExternalLinks(title: title)
                    RatingControl(kind: .tv, tmdbID: title.tmdbID, rating: rating)
                    div(.class("title-actions")) {
                        WatchLaterToggle(kind: .tv, tmdbID: title.tmdbID, onList: watchLater)
                        FollowToggle(tmdbID: title.tmdbID, followed: followed)
                        HiddenToggle(tmdbID: title.tmdbID, hidden: hidden)
                    }
                    CommentBox(id: "series-comment", action: "/tv/\(title.tmdbID)/comment", caption: "Kommentar zur Serie", comment: comment)
                }
            }
            if let availability { AvailabilityBlock(view: availability) }
            if seasons.isEmpty {
                p(.class("muted")) { "Für diese Serie sind keine Folgen bekannt." }
            } else {
                SeriesWatchForm(tmdbID: title.tmdbID, defaultService: defaultService, rewatch: SeasonModel.seriesFullyWatched(seasons))
            }
            SeasonsList(tmdbID: title.tmdbID, seasons: seasons, today: today, defaultService: defaultService)
        }
    }
}
