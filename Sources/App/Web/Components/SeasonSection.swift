import Elementary
import ElementaryHTMX2

struct EpisodeRowModel {
    let info: EpisodeInfo
    let aired: Bool
    /// The user's watches of this episode, most recent first.
    let watches: [Watch]

    var watched: Bool { !watches.isEmpty }
}

struct SeasonModel {
    let number: Int
    let episodes: [EpisodeRowModel]
    var isOpen: Bool
    var comment: String? = nil
    /// Episode number whose details stay open after marking it from its form („Gesehen“, „bis hier gesehen“).
    var openEpisode: Int? = nil

    var watchedCount: Int { episodes.filter(\.watched).count }
    var title: String { number == 0 ? "Specials" : "Staffel \(number)" }
    /// Every aired episode is watched (and there is one): „Ganze Staffel erneut gesehen“.
    var fullyWatched: Bool { Self.allWatched(episodes) }

    /// Every aired regular episode (season ≥ 1) is watched: „Gesamte Serie erneut gesehen“.
    static func seriesFullyWatched(_ seasons: [SeasonModel]) -> Bool {
        allWatched(seasons.filter { $0.number > 0 }.flatMap(\.episodes))
    }

    private static func allWatched(_ episodes: [EpisodeRowModel]) -> Bool {
        let aired = episodes.filter(\.aired)
        return !aired.isEmpty && aired.allSatisfy(\.watched)
    }
}

/// Watch summary line: "07.11.2026 · Netflix", "ohne Datum", "×2".
func watchSummary(_ watches: [Watch]) -> String {
    guard let latest = watches.first else { return "" }
    var parts: [String] = [latest.watchedOn.map(CalendarDay.display) ?? "ohne Datum"]
    if let service = latest.streamingService { parts.append(service.label) }
    if watches.count > 1 { parts.append("×\(watches.count)") }
    return parts.joined(separator: " · ")
}

struct SeasonSection: HTML {
    let tmdbID: Int
    let season: SeasonModel
    let today: String
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

struct EpisodeRow: HTML {
    let tmdbID: Int
    let model: EpisodeRowModel
    let today: String
    let defaultService: StreamingService?
    /// Details shown expanded (the episode was just marked from its form).
    var open = false

    private var path: String { "/tv/\(tmdbID)/episodes/\(model.info.season)/\(model.info.number)" }
    private var target: String { "#season-\(model.info.season)" }
    private var hasDetails: Bool { model.aired || !(model.info.overview ?? "").isEmpty }

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

struct SeasonsList: HTML {
    let tmdbID: Int
    let seasons: [SeasonModel]
    let today: String
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
    let section: Section
    let refresh: BulkServiceRefresh

    var body: some HTML {
        section
        refresh
    }
}
