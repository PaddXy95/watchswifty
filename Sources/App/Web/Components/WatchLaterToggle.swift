import Elementary
import ElementaryHTMX2

/// „Später ansehen“ switch on the series and movie page.
///
/// The button (`#watch-later-toggle`) posts the opposite state to `/<kind>/<id>/watch-later` and replaces itself with
/// the response; `aria-pressed` reflects whether the title is on the list.
struct WatchLaterToggle: HTML {
    /// Series or movie; selects the route prefix (`tv` / `movie`).
    let kind: TitleKind
    /// TMDB ID of the title.
    let tmdbID: Int
    /// Whether the title is on „Später ansehen“ (watch later); the button posts the opposite.
    let onList: Bool

    var body: some HTML {
        button(.id("watch-later-toggle"), .class(onList ? "follow-toggle active" : "follow-toggle"),
               .hx.post("/\(kind.rawValue)/\(tmdbID)/watch-later"), .hx.vals(#"{"watchLater":"\#(!onList)"}"#), .hx.swap(.outerHTML),
               .custom(name: "aria-pressed", value: onList ? "true" : "false")) {
            onList ? "✓ Später ansehen" : "Später ansehen"
        }
    }
}
