import Elementary
import ElementaryHTMX2

/// „Beobachten“ switch on the series page.
///
/// The button (`#follow-toggle`) posts the opposite state to `/tv/<id>/follow` and replaces itself with the response;
/// `aria-pressed` reflects whether the series is followed.
struct FollowToggle: HTML {
    /// TMDB ID of the series.
    let tmdbID: Int
    /// Whether the user follows the series; the button posts the opposite.
    let followed: Bool

    var body: some HTML {
        button(.id("follow-toggle"), .class(followed ? "follow-toggle active" : "follow-toggle"),
               .hx.post("/tv/\(tmdbID)/follow"), .hx.vals(#"{"followed":"\#(!followed)"}"#), .hx.swap(.outerHTML),
               .custom(name: "aria-pressed", value: followed ? "true" : "false")) {
            followed ? "🔕 Nicht mehr beobachten" : "🔔 Beobachten"
        }
    }
}
