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

    var watchedCount: Int { episodes.filter(\.watched).count }
    var title: String { number == 0 ? "Specials" : "Staffel \(number)" }
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
                button(.class("season-action"), .hx.post("/tv/\(tmdbID)/seasons/\(season.number)/watch"),
                       .hx.target("#season-\(season.number)"), .hx.swap(.outerHTMLGuarded)) { "Ganze Staffel gesehen" }
            }
            for episode in season.episodes {
                EpisodeRow(tmdbID: tmdbID, model: episode, today: today, defaultService: defaultService)
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

    private var path: String { "/tv/\(tmdbID)/episodes/\(model.info.season)/\(model.info.number)" }
    private var target: String { "#season-\(model.info.season)" }

    var body: some HTML {
        div(.class("episode-row"), .id("ep-\(model.info.season)-\(model.info.number)")) {
            if model.aired {
                if model.watched {
                    input(.type(.checkbox), .checked, .hx.delete("\(path)/watch"), .hx.target(target), .hx.swap(.outerHTMLGuarded),
                          .custom(name: "aria-label", value: "\(model.info.code) als ungesehen markieren"))
                } else {
                    input(.type(.checkbox), .hx.post("\(path)/watch"), .hx.target(target), .hx.swap(.outerHTMLGuarded),
                          .custom(name: "aria-label", value: "\(model.info.code) als gesehen markieren"))
                }
            } else {
                input(.type(.checkbox), .disabled, .custom(name: "aria-label", value: "\(model.info.code) noch nicht erschienen"))
            }
            span(.class("code")) { model.info.code }
            span(.class("name")) { model.info.name }
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
            if model.aired || !(model.info.overview ?? "").isEmpty {
                details(.class("episode-menu")) {
                    summary { "Details" }
                    if let overview = model.info.overview, !overview.isEmpty {
                        p(.class("episode-overview")) { overview }
                    }
                    if model.aired {
                        WatchForm(action: "\(path)/watch", target: target, submitLabel: model.watched ? "Erneut gesehen" : "Gesehen",
                                  rewatch: model.watched, today: today, defaultService: defaultService)
                        button(.hx.post("\(path)/watch-up-to"), .hx.target("#seasons"), .hx.swap(.outerHTMLGuarded)) { "bis hier gesehen" }
                    }
                }
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
