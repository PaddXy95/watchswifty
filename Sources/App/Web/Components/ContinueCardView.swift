import Elementary
import ElementaryHTMX2
import Foundation

/// Card for one series on the „Weiterschauen“ (continue watching) page: poster, next episode, episodes left, last
/// service and rating, with „✓ gesehen“ (watched), „Ausblenden“ (hide) and, if known, a link to the streaming service.
///
/// The card (`#card-<tmdbID>`) is htmx-boosted. „✓ gesehen“ posts the next episode to `/tv/<id>/next` and replaces the
/// closest `.card` with the response. The poster link is left out of the tab order, since the title links to the same
/// page.
struct ContinueCardView: HTML {
    /// The continue-watching entry to render.
    let card: ContinueCard

    /// „noch 1 Folge“ / „noch n Folgen“ (n episodes left).
    private var remainingText: String { card.remaining == 1 ? "noch 1 Folge" : "noch \(card.remaining) Folgen" }

    var body: some HTML {
        article(.class("card continue-card"), .id("card-\(card.tmdbID)"), .hx.boost(true)) {
            a(.href("/tv/\(card.tmdbID)"), .custom(name: "tabindex", value: "-1"),
              .custom(name: "hx-indicator", value: "closest .card, #page-loader")) { Poster(path: card.posterPath, alt: card.name) }
            div(.class("card-body")) {
                h2(.class("card-title")) {
                    a(.href("/tv/\(card.tmdbID)"), .custom(name: "hx-indicator", value: "closest .card, #page-loader")) { card.name }
                }
                if let last = card.lastWatchedOn {
                    p(.class("muted")) { "zuletzt \(CalendarDay.display(last))" }
                }
                p { "Weiter mit \(card.next.code) · „\(card.next.name)“" }
                p(.class("meta")) {
                    remainingText
                    if let service = card.lastService { " · zuletzt auf \(service.label)" }
                    if let rating = card.rating { " · "; span(.class("rating")) { "★ \(rating)" } }
                }
                div(.class("actions")) {
                    button(.class("primary"), .hx.post("/tv/\(card.tmdbID)/next"),
                           .hx.vals(#"{"episodeID":"\#(card.next.id.uuidString)"}"#),
                           .hx.target("closest .card"), .hx.swap(.outerHTMLGuarded)) { "✓ gesehen" }
                    HiddenToggle(tmdbID: card.tmdbID, hidden: false, context: .card)
                    if let link = card.watchService?.watchLink(for: card.name) {
                        a(.class("button"), .href(link.url), .target(.blank),
                          .custom(name: "rel", value: "noopener noreferrer"), .hx.boost(false)) { link.label }
                    }
                }
            }
        }
    }
}
