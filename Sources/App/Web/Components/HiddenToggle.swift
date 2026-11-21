import Elementary
import ElementaryHTMX2

/// "Ausblenden"/"Einblenden" button. In `card` context a successful hide removes the card.
///
/// On the series page the button (`#hidden-toggle`) posts the opposite state to `/tv/<id>/hidden` and replaces itself.
/// On a continue-watching card it only hides (sending `context=card`) and replaces the closest `.card`.
struct HiddenToggle: HTML {
    /// Where the button is rendered: `page` (series page, toggles both ways) or `card` (continue-watching card, hide
    /// only).
    enum Context: String { case page, card }

    /// TMDB ID of the series.
    let tmdbID: Int
    /// Whether the series is hidden; on the page it selects „Einblenden“ (show) or „Ausblenden“ (hide). Ignored in
    /// `card` context.
    let hidden: Bool
    /// Rendering context; defaults to the series page.
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
