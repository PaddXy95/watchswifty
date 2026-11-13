import Elementary
import ElementaryHTMX2
import Foundation

/// The viewings of one episode or movie, newest first, each with „Löschen“ (asks first). The response replaces
/// `target`.
struct WatchList: HTML {
    let watches: [Watch]
    /// `DELETE \(deletePrefix)/<watch id>` deletes one viewing.
    let deletePrefix: String
    let target: String

    var body: some HTML {
        ul(.class("watch-list")) {
            for watch in watches {
                li {
                    span { watchSummary([watch]) }
                    button(.type(.button), .hx.delete("\(deletePrefix)/\(watch.id?.uuidString ?? "")"),
                           .hx.confirm("Diese Sichtung löschen?"), .hx.target(target), .hx.swap(.outerHTMLGuarded)) { "Löschen" }
                }
            }
        }
    }
}
