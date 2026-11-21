import Elementary
import ElementaryHTMX2

/// Date + service form used for marking (or re-marking) an episode or movie.
struct WatchForm: HTML {
    /// URL the form posts to.
    let action: String
    /// htmx target (CSS selector) the response replaces.
    let target: String
    /// Text of the submit button, e.g. „Gesehen“ (watched).
    let submitLabel: String
    /// Adds a hidden `rewatch=true` field (marking something already watched again).
    let rewatch: Bool
    /// Today (`YYYY-MM-DD`): default value and maximum of the date input.
    let today: String
    /// Service preselected in the „Dienst“ (service) choice.
    let defaultService: StreamingService?
    /// Episode forms: the episode stays expanded after the swap.
    var keepOpen = false
    /// Episode forms: „bis hier gesehen“ posts here with this form's service.
    var upToAction: String? = nil

    var body: some HTML {
        form(.class("watch-form"), .hx.post(action), .hx.target(target), .hx.swap(.outerHTML)) {
            label {
                "Datum"
                input(.type(.date), .name("day"), .value(today), .max(today), .required)
            }
            ServiceSelect(selected: defaultService)
            if rewatch {
                input(.type(.hidden), .name("rewatch"), .value("true"))
            }
            if keepOpen {
                input(.type(.hidden), .name("open"), .value("1"))
            }
            button(.type(.submit), .class("primary")) { submitLabel }
            if let upToAction {
                // Inside the form, so htmx sends its service along (the date is ignored: „bis hier“ is undated).
                button(.type(.button), .class("up-to"), .hx.post(upToAction), .hx.target("#seasons"), .hx.swap(.outerHTMLGuarded)) { "bis hier gesehen" }
            }
        }
    }
}

/// „Dienst“ choice: „unbekannt“ (empty) or a streaming service, preselected with the last one used.
struct ServiceSelect: HTML {
    /// The preselected service; `nil` selects „unbekannt“ (unknown).
    let selected: StreamingService?
    /// Set for the season/series forms, so marking elsewhere can refresh their preselection.
    var id: String? = nil
    /// Rendered as an htmx out-of-band swap (replaces the element with the same id).
    var outOfBand = false

    /// Element id of the series form's service choice.
    /// - Returns: `series-service`.
    static func seriesID() -> String { "series-service" }
    /// Element id of a season form's service choice.
    /// - Parameter season: Season number.
    /// - Returns: `season-service-<season>`.
    static func seasonID(_ season: Int) -> String { "season-service-\(season)" }

    var body: some HTML {
        label(.class("service-select")) {
            "Dienst"
            select(.name("service")) {
                option(.value("")) { "unbekannt" }.attributes(.selected, when: selected == nil)
                for service in StreamingService.allCases {
                    option(.value(service.rawValue)) { service.label }.attributes(.selected, when: service == selected)
                }
            }
        }
        .attributes(.id(id ?? ""), when: id != nil)
        .attributes(.custom(name: "hx-swap-oob", value: "true"), when: outOfBand)
    }
}

/// Out-of-band refresh of the forms outside the swapped part after a watch: the series form (its service choice and
/// whether it marks a new round) and the other seasons' service choices; they would otherwise keep their stale state
/// (and save it).
struct BulkServiceRefresh: HTML {
    /// TMDB ID of the series.
    let tmdbID: Int
    /// Service to preselect in every refreshed form (the one used last for the series).
    let selected: StreamingService?
    /// Every aired regular episode is watched: the series form offers „Gesamte Serie erneut gesehen“.
    let seriesRewatch: Bool
    /// Seasons whose form is not part of the swapped content.
    let seasons: [Int]

    var body: some HTML {
        SeriesWatchForm(tmdbID: tmdbID, defaultService: selected, rewatch: seriesRewatch, outOfBand: true)
        for season in seasons where season > 0 {
            ServiceSelect(selected: selected, id: ServiceSelect.seasonID(season), outOfBand: true)
        }
    }
}

/// „Gesamte Serie gesehen“, or „Gesamte Serie erneut gesehen“ once every aired regular episode is watched (a new
/// round, see `WatchService.markSeries`).
///
/// The form (`#series-action`) posts to `/tv/<id>/watch-all` after a confirmation and replaces `#seasons`.
struct SeriesWatchForm: HTML {
    /// Element id of the form, which the out-of-band swap replaces.
    static let id = "series-action"

    /// TMDB ID of the series.
    let tmdbID: Int
    /// Service preselected in the „Dienst“ (service) choice.
    let defaultService: StreamingService?
    /// Every aired regular episode is watched: offers „Gesamte Serie erneut gesehen“ and sends `rewatch=true`.
    let rewatch: Bool
    /// Rendered as an htmx out-of-band swap (replaces `#series-action`).
    var outOfBand = false

    var body: some HTML {
        form(.class("series-action"), .id(Self.id), .hx.post("/tv/\(tmdbID)/watch-all"),
             .hx.confirm(rewatch ? "Alle erschienenen Folgen noch einmal als gesehen markieren?" : "Alle erschienenen Folgen als gesehen markieren?"),
             .hx.target("#seasons"), .hx.swap(.outerHTMLGuarded)) {
            ServiceSelect(selected: defaultService, id: ServiceSelect.seriesID())
            if rewatch { input(.type(.hidden), .name("rewatch"), .value("true")) }
            button(.type(.submit)) { rewatch ? "Gesamte Serie erneut gesehen" : "Gesamte Serie gesehen" }
        }
        .attributes(.custom(name: "hx-swap-oob", value: "true"), when: outOfBand)
    }
}
