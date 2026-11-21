import Elementary
import ElementaryHTMX2

/// Movie detail page at `/movie/:tmdbID`.
///
/// The header holds poster, runtime and genres, overview, external links, rating, the „Später ansehen“ (watch later)
/// toggle and the movie comment; below follow the streaming availability (when given) and `MovieWatchesSection`.
struct MoviePage: HTML {
    let nav: NavContext
    /// The cached movie.
    let title: Title
    /// The user's viewings of the movie.
    let watches: [Watch]
    /// The user's rating (1–10), nil when unrated.
    let rating: Int?
    /// The user's comment on the movie.
    let comment: String?
    /// Today (`YYYY-MM-DD`) for the date default of the watch form.
    let today: String
    /// The movie is on the user's „Später ansehen“ list.
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
                    div(.class("title-actions")) {
                        WatchLaterToggle(kind: .movie, tmdbID: title.tmdbID, onList: watchLater)
                    }
                    CommentBox(id: "movie-comment", action: "/movie/\(title.tmdbID)/comment", caption: "Kommentar zum Film", comment: comment)
                }
            }
            if let availability { AvailabilityBlock(view: availability) }
            MovieWatchesSection(tmdbID: title.tmdbID, watches: watches, today: today)
        }
    }
}

/// The `#movie-watches` section: the user's viewings of a movie and the form to add one.
///
/// The watch form and the delete buttons target `#movie-watches`; marking the movie and deleting a viewing return this
/// fragment. The submit label becomes „Erneut gesehen“ (watched again) once there is a viewing, and the last viewing's
/// service is preselected.
struct MovieWatchesSection: HTML {
    /// TMDB ID of the movie (for the action URLs).
    let tmdbID: Int
    let watches: [Watch]
    /// Today (`YYYY-MM-DD`) for the date default of the watch form.
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
