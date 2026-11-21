import Elementary
import Foundation
import ElementaryHTMX2

/// One table row of the „Verlauf“ (history) page: date, title (and episode), service, origin, with „Bearbeiten“ (edit)
/// and „Löschen“ (delete).
///
/// The row id is `watch-<watch id>`. The inline edit form (posts to `/watches/<id>`) and the delete button (after a
/// confirmation) replace the closest `<tr>` with the response. Cells carry `data-label`, which the narrow layout shows
/// as captions.
struct HistoryRow: HTML {
    /// The viewing shown in this row.
    let watch: Watch
    /// The watched title.
    let title: Title
    /// The watched episode, or `nil` for a movie.
    let episode: Episode?
    /// Today (`YYYY-MM-DD`): maximum of the date input and its value for undated viewings.
    let today: String

    var body: some HTML {
        tr(.class("history-row"), .id("watch-\(watch.id?.uuidString ?? "")")) {
            td(.data("label", value: "Datum")) { watch.watchedOn.map(CalendarDay.display) ?? "ohne Datum" }
            td(.data("label", value: "Titel")) {
                a(.href("/\(title.kind)/\(title.tmdbID)")) { title.name }
                if let episode { br(); span(.class("muted")) { "\(episode.code) · \(episode.name)" } }
            }
            td(.data("label", value: "Dienst")) { watch.streamingService?.label ?? "unbekannt" }
            td(.data("label", value: "Herkunft")) { watch.watchOrigin == .import ? "Import" : "manuell" }
            td {
                let path = "/watches/\(watch.id?.uuidString ?? "")"
                details(.class("history-edit")) {
                    summary { "Bearbeiten" }
                    form(.class("watch-form"), .hx.post(path), .hx.target("closest tr"), .hx.swap(.outerHTML)) {
                        label { "Datum"; input(.type(.date), .name("day"), .value(watch.watchedOn ?? today), .max(today), .required) }
                        label {
                            "Dienst"
                            select(.name("service")) {
                                option(.value("")) { "unbekannt" }.attributes(.selected, when: watch.streamingService == nil)
                                for service in StreamingService.allCases {
                                    option(.value(service.rawValue)) { service.label }.attributes(.selected, when: service == watch.streamingService)
                                }
                            }
                        }
                        button(.type(.submit)) { "Speichern" }
                    }
                }
                button(.hx.delete(path), .hx.confirm("Diesen Eintrag löschen?"), .hx.target("closest tr"), .hx.swap(.outerHTML)) { "Löschen" }
            }
        }
    }
}

/// One page of history rows, followed by a „Mehr laden“ (load more) row when there is a next page.
///
/// The button fetches `/history?page=<n>` and replaces its own row (`#more-row`), so the next page is appended.
struct HistoryRows: HTML {
    /// (watch, title, episode) triples in display order.
    let rows: [(Watch, Title, Episode?)]
    /// Number of the next page, or `nil` on the last page.
    let nextPage: Int?
    /// Today (`YYYY-MM-DD`), passed to every ``HistoryRow``.
    let today: String

    var body: some HTML {
        for (watch, title, episode) in rows {
            HistoryRow(watch: watch, title: title, episode: episode, today: today)
        }
        if let nextPage {
            tr(.id("more-row")) {
                td(.custom(name: "colspan", value: "5")) {
                    button(.hx.get("/history?page=\(nextPage)"), .hx.target("closest tr"), .hx.swap(.outerHTML)) { "Mehr laden" }
                }
            }
        }
    }
}
