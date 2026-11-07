import Elementary
import ElementaryHTMX2
import Foundation

func netflixSearchURL(_ name: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return "https://www.netflix.com/search?q=" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
}

struct ContinueCardView: HTML {
    let card: ContinueCard

    private var remainingText: String { card.remaining == 1 ? "noch 1 Folge" : "noch \(card.remaining) Folgen" }

    var body: some HTML {
        article(.class("card continue-card"), .id("card-\(card.tmdbID)")) {
            a(.href("/tv/\(card.tmdbID)"), .custom(name: "tabindex", value: "-1")) { Poster(path: card.posterPath, alt: card.name) }
            div(.class("card-body")) {
                h2(.class("card-title")) {
                    a(.href("/tv/\(card.tmdbID)")) { card.name }
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
                    if card.hasNetflixData {
                        a(.class("button"), .href(netflixSearchURL(card.name)), .target(.blank),
                          .custom(name: "rel", value: "noopener noreferrer")) { "Auf Netflix suchen" }
                    }
                }
            }
        }
    }
}
