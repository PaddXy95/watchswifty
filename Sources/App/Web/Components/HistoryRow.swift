import Elementary
import Foundation
import ElementaryHTMX2

struct HistoryRow: HTML {
    let watch: Watch
    let title: Title
    let episode: Episode?
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

struct HistoryRows: HTML {
    let rows: [(Watch, Title, Episode?)]
    let nextPage: Int?
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
