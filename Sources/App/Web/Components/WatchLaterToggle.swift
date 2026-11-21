import Elementary
import ElementaryHTMX2

/// „Später ansehen“ switch on the series and movie page.
struct WatchLaterToggle: HTML {
    let kind: TitleKind
    let tmdbID: Int
    let onList: Bool

    var body: some HTML {
        button(.id("watch-later-toggle"), .class(onList ? "follow-toggle active" : "follow-toggle"),
               .hx.post("/\(kind.rawValue)/\(tmdbID)/watch-later"), .hx.vals(#"{"watchLater":"\#(!onList)"}"#), .hx.swap(.outerHTML),
               .custom(name: "aria-pressed", value: onList ? "true" : "false")) {
            onList ? "✓ Später ansehen" : "Später ansehen"
        }
    }
}
