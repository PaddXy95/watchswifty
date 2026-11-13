import Elementary
import ElementaryHTMX2
import Foundation

/// Konto → TMDB-Token: reload all titles from TMDB. While a run is going the fragment asks every 2 s for the
/// progress (like the Netflix import); otherwise it shows the last result and the button.
struct LibraryRefreshStatus: HTML {
    let state: LibraryRefreshState
    /// A start that was refused (e.g. no token).
    var error: String? = nil

    var body: some HTML {
        if state.running {
            div(.id("library-refresh"), .class("library-refresh"), .hx.get("/account/tmdb-refresh"),
                .custom(name: "hx-trigger", value: "every 2s"), .hx.swap(.outerHTML)) {
                p(.class("notice"), .custom(name: "role", value: "status")) { "Lädt neu … \(state.done) von \(state.total)" }
            }
        } else {
            div(.id("library-refresh"), .class("library-refresh")) {
                if let message = error ?? state.error {
                    p(.class("error"), .custom(name: "role", value: "alert")) { message }
                } else if state.finishedAt != nil {
                    p(.class("notice"), .custom(name: "role", value: "status")) {
                        "Fertig: \(state.refreshed) Titel neu geladen"
                        if state.failed > 0 { ", \(state.failed) fehlgeschlagen" }
                        " · "
                        a(.href("/library")) { "Zur Bibliothek" }
                    }
                }
                p(.class("muted")) { "Lädt alle deine Serien und Filme mit diesem Token neu von TMDB." }
                form(.method(.post), .action("/account/tmdb-refresh"), .class("inline-form"), .hx.post("/account/tmdb-refresh"),
                     .hx.target("#library-refresh"), .hx.swap(.outerHTML)) {
                    button(.type(.submit)) { "Alle Daten von TMDB neu laden" }
                }
            }
        }
    }
}
