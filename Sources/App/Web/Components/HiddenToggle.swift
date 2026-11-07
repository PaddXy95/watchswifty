import Elementary
import ElementaryHTMX2

/// "Ausblenden"/"Einblenden" button. In `card` context a successful hide removes the card.
struct HiddenToggle: HTML {
    enum Context: String { case page, card }

    let tmdbID: Int
    let hidden: Bool
    var context: Context = .page

    var body: some HTML {
        switch context {
        case .page:
            button(.id("hidden-toggle"), .hx.post("/tv/\(tmdbID)/hidden"), .hx.vals(#"{"hidden":"\#(!hidden)"}"#),
                   .hx.swap(.outerHTML)) { hidden ? "Einblenden" : "Ausblenden" }
        case .card:
            button(.hx.post("/tv/\(tmdbID)/hidden"), .hx.vals(#"{"hidden":"true","context":"card"}"#),
                   .hx.target("closest .card"), .hx.swap(.outerHTML)) { "Ausblenden" }
        }
    }
}
