import Elementary
import ElementaryHTMX2

/// View model of one episode row on the series page.
struct EpisodeRowModel {
    /// Catalog data of the episode.
    let info: EpisodeInfo
    /// Whether the episode has aired.
    let aired: Bool
    /// The user's watches of this episode, most recent first.
    let watches: [Watch]

    /// Whether the user has at least one viewing of the episode.
    var watched: Bool { !watches.isEmpty }
}

/// View model of one season section on the series page.
struct SeasonModel {
    /// Season number; 0 is „Specials“.
    let number: Int
    /// The season's episode rows in order.
    let episodes: [EpisodeRowModel]
    /// Renders the season's `<details>` expanded.
    var isOpen: Bool
    /// The user's private comment on the season.
    var comment: String? = nil
    /// Episode number whose details stay open after marking it from its form („Gesehen“, „bis hier gesehen“).
    var openEpisode: Int? = nil

    /// Number of episodes with at least one viewing.
    var watchedCount: Int { episodes.filter(\.watched).count }
    /// „Specials“ for season 0, otherwise „Staffel n“ (season n).
    var title: String { number == 0 ? "Specials" : "Staffel \(number)" }
    /// Every aired episode is watched (and there is one): „Ganze Staffel erneut gesehen“.
    var fullyWatched: Bool { Self.allWatched(episodes) }

    /// Every aired regular episode (season ≥ 1) is watched: „Gesamte Serie erneut gesehen“.
    /// - Parameter seasons: All seasons of the series.
    /// - Returns: `true` if there is an aired regular episode and every one is watched.
    static func seriesFullyWatched(_ seasons: [SeasonModel]) -> Bool {
        allWatched(seasons.filter { $0.number > 0 }.flatMap(\.episodes))
    }

    /// Whether there is at least one aired episode and every aired one is watched.
    /// - Parameter episodes: The episodes to check.
    /// - Returns: `true` if all aired episodes are watched (and there is one).
    private static func allWatched(_ episodes: [EpisodeRowModel]) -> Bool {
        let aired = episodes.filter(\.aired)
        return !aired.isEmpty && aired.allSatisfy(\.watched)
    }
}

/// Watch summary line: "07.11.2026 · Netflix", "ohne Datum", "×2".
/// - Parameter watches: Viewings, newest first.
/// - Returns: Date (or „ohne Datum“ (undated)) and service of the newest viewing, plus the count if there are several;
///   an empty string without viewings.
func watchSummary(_ watches: [Watch]) -> String {
    guard let latest = watches.first else { return "" }
    var parts: [String] = [latest.watchedOn.map(CalendarDay.display) ?? "ohne Datum"]
    if let service = latest.streamingService { parts.append(service.label) }
    if watches.count > 1 { parts.append("×\(watches.count)") }
    return parts.joined(separator: " · ")
}

/// One season on the series page as a foldable `<details id="season-<n>">`: the watched count, the „Ganze Staffel
/// gesehen“ (whole season watched) form for regular seasons, the episode rows and the season comment.
///
/// The season form posts to `/tv/<id>/seasons/<n>/watch` and replaces the section. Once the season is fully watched it
/// becomes „Ganze Staffel erneut gesehen“ (watched again), sends `rewatch=true` and asks for confirmation first.
struct SeasonSection: HTML {
    /// TMDB ID of the series.
    let tmdbID: Int
    /// The season to render.
    let season: SeasonModel
    /// Today (`YYYY-MM-DD`), for the episodes' watch forms.
    let today: String
    /// Service preselected in the forms (the one used last).
    let defaultService: StreamingService?

    var body: some HTML {
        details(.id("season-\(season.number)"), .class("season")) {
            summary { "\(season.title) · \(season.watchedCount)/\(season.episodes.count) gesehen" }
            if season.number > 0 {
                form(.class("season-action"), .hx.post("/tv/\(tmdbID)/seasons/\(season.number)/watch"),
                     .hx.target("#season-\(season.number)"), .hx.swap(.outerHTMLGuarded)) {
                    ServiceSelect(selected: defaultService, id: ServiceSelect.seasonID(season.number))
                    if season.fullyWatched { input(.type(.hidden), .name("rewatch"), .value("true")) }
                    button(.type(.submit)) { season.fullyWatched ? "Ganze Staffel erneut gesehen" : "Ganze Staffel gesehen" }
                }
                .attributes(.hx.confirm("Alle Folgen der Staffel noch einmal als gesehen markieren?"), when: season.fullyWatched)
            }
            for episode in season.episodes {
                EpisodeRow(tmdbID: tmdbID, model: episode, today: today, defaultService: defaultService,
                           open: season.openEpisode == episode.info.number)
            }
            CommentBox(id: "season-comment-\(season.number)", action: "/tv/\(tmdbID)/seasons/\(season.number)/comment",
                       caption: "Kommentar zur Staffel", comment: season.comment)
        }
        .attributes(.custom(name: "open", value: ""), when: season.isOpen)
    }
}

/// One episode row (`#ep-<season>-<number>`): a watch mark and the title line, which opens details with the overview,
/// the viewings and the watch form.
///
/// Watched episodes show a check mark, aired ones a button that marks them watched today, unaired ones a dimmed circle
/// (each with an `aria-label`). Every action replaces the whole season section, „bis hier gesehen“ (watched up to
/// here) all of `#seasons`. Without anything to show (not aired, not watched, no overview) the title line is not
/// expandable.
struct EpisodeRow: HTML {
    /// TMDB ID of the series.
    let tmdbID: Int
    /// The episode to render.
    let model: EpisodeRowModel
    /// Today (`YYYY-MM-DD`), for the watch form.
    let today: String
    /// Service preselected in the watch form.
    let defaultService: StreamingService?
    /// Details shown expanded (the episode was just marked from its form).
    var open = false

    /// Base URL of the episode's routes (`/tv/<id>/episodes/<season>/<number>`).
    private var path: String { "/tv/\(tmdbID)/episodes/\(model.info.season)/\(model.info.number)" }
    /// htmx target of the row's actions (all but „bis hier gesehen“): the season section.
    private var target: String { "#season-\(model.info.season)" }
    /// Whether the row has an expandable details panel (aired, watched or with an overview).
    /// Watched counts too: TMDB may move an air date after the episode was watched, and its viewings stay deletable.
    private var hasDetails: Bool { model.aired || model.watched || !(model.info.overview ?? "").isEmpty }

    var body: some HTML {
        div(.class("episode-row"), .id("ep-\(model.info.season)-\(model.info.number)")) {
            // Watched: a green check (removing goes through the list in the details). Aired: one click marks it as
            // watched today. Not aired yet: a dimmed circle.
            if model.watched {
                span(.class("watched-mark"), .role("img"), .custom(name: "aria-label", value: "gesehen")) { "✓" }
            } else if model.aired {
                button(.type(.button), .class("watch-mark"), .hx.post("\(path)/watch"), .hx.target(target), .hx.swap(.outerHTMLGuarded),
                       .custom(name: "aria-label", value: "\(model.info.code) als gesehen markieren")) {}
            } else {
                span(.class("watch-mark unaired"), .role("img"),
                     .custom(name: "aria-label", value: "\(model.info.code) noch nicht erschienen")) {}
            }
            // The title opens the details (checkbox stays outside the summary: no control inside a summary).
            if hasDetails {
                details(.class("episode")) {
                    summary(.class("episode-summary")) { summaryLine }
                    div(.class("episode-panel")) {
                        if let overview = model.info.overview, !overview.isEmpty {
                            p(.class("episode-overview")) { overview }
                        }
                        if model.watched {
                            WatchList(watches: model.watches, deletePrefix: "\(path)/watches", target: target)
                        }
                        if model.aired {
                            WatchForm(action: "\(path)/watch", target: target, submitLabel: model.watched ? "Erneut gesehen" : "Gesehen",
                                      rewatch: model.watched, today: today, defaultService: defaultService, keepOpen: true,
                                      upToAction: "\(path)/watch-up-to")
                        }
                    }
                }
                .attributes(.custom(name: "open", value: ""), when: open)
            } else {
                div(.class("episode-summary")) { summaryLine }
            }
        }
    }

    /// Episode code, name, runtime and a meta text: the watch summary, or the air date for unaired episodes.
    @HTMLBuilder private var summaryLine: some HTML {
        span(.class("code")) { model.info.code }
        span(.class("name episode-title")) { model.info.name }
        if let runtime = model.info.runtime, runtime > 0 {
            span(.class("runtime")) { formatDuration(minutes: runtime) }
        }
        span(.class("meta")) {
            if model.watched {
                watchSummary(model.watches)
            } else if !model.aired {
                model.info.airDate.map { "erscheint \(CalendarDay.display($0))" } ?? "noch nicht erschienen"
            }
        }
    }
}

/// All season sections inside `#seasons`, the target of the series-wide and „bis hier gesehen“ (watched up to here)
/// actions.
struct SeasonsList: HTML {
    /// TMDB ID of the series.
    let tmdbID: Int
    /// The seasons in display order.
    let seasons: [SeasonModel]
    /// Today (`YYYY-MM-DD`), for the episodes' watch forms.
    let today: String
    /// Service preselected in the forms (the one used last).
    let defaultService: StreamingService?

    var body: some HTML {
        div(.id("seasons")) {
            for season in seasons {
                SeasonSection(tmdbID: tmdbID, season: season, today: today, defaultService: defaultService)
            }
        }
    }
}

/// Swapped content followed by the out-of-band service refresh.
struct SeasonUpdate<Section: HTML>: HTML {
    /// The main swapped fragment (a season section or the whole season list).
    let section: Section
    /// Out-of-band updates of the forms outside `section`.
    let refresh: BulkServiceRefresh

    var body: some HTML {
        section
        refresh
    }
}
