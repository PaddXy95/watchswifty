import Elementary
import ElementaryHTMX2

/// Date + service form used for marking (or re-marking) an episode or movie.
struct WatchForm: HTML {
    let action: String
    let target: String
    let submitLabel: String
    let rewatch: Bool
    let today: String
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
    let selected: StreamingService?
    /// Set for the season/series forms, so marking elsewhere can refresh their preselection.
    var id: String? = nil
    /// Rendered as an htmx out-of-band swap (replaces the element with the same id).
    var outOfBand = false

    static func seriesID() -> String { "series-service" }
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

/// Out-of-band refresh of the season/series service choices after a watch changed the last used service; the forms
/// outside the swapped part would otherwise keep their stale preselection (and save it).
struct BulkServiceRefresh: HTML {
    let selected: StreamingService?
    /// Seasons whose form is not part of the swapped content.
    let seasons: [Int]

    var body: some HTML {
        ServiceSelect(selected: selected, id: ServiceSelect.seriesID(), outOfBand: true)
        for season in seasons where season > 0 {
            ServiceSelect(selected: selected, id: ServiceSelect.seasonID(season), outOfBand: true)
        }
    }
}
