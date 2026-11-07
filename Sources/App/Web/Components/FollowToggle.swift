import Elementary
import ElementaryHTMX2

/// „Beobachten“ switch on the series page.
struct FollowToggle: HTML {
    let tmdbID: Int
    let followed: Bool

    var body: some HTML {
        button(.id("follow-toggle"), .class(followed ? "follow-toggle active" : "follow-toggle"),
               .hx.post("/tv/\(tmdbID)/follow"), .hx.vals(#"{"followed":"\#(!followed)"}"#), .hx.swap(.outerHTML),
               .custom(name: "aria-pressed", value: followed ? "true" : "false")) {
            followed ? "🔕 Nicht mehr beobachten" : "🔔 Beobachten"
        }
    }
}
