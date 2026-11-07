import Elementary
import ElementaryHTMX2

/// „Neue Folgen“ box on the start page (followed series only).
struct NewEpisodesBox: HTML {
    let notes: [NewEpisodesNote]

    var body: some HTML {
        aside(.class("new-episodes"), .custom(name: "aria-label", value: "Neue Folgen")) {
            h2 { "🔔 Neue Folgen" }
            ul {
                for note in notes {
                    li(.class("new-episode-note")) {
                        a(.href("/tv/\(note.tmdbID)"), .hx.boost(true)) { strong { note.name } }
                        span(.class("muted")) { note.count == 1 ? "1 neue Folge" : "\(note.count) neue Folgen" }
                        span(.class("muted")) {
                            "ab \(note.first.code)"
                            if let air = note.first.airDate { " · \(CalendarDay.display(air))" }
                        }
                        button(.class("link-button"), .hx.post("/tv/\(note.tmdbID)/new-episodes/dismiss"),
                               .hx.target("closest li"), .hx.swap(.outerHTML)) { "Erledigt" }
                    }
                }
            }
        }
    }
}
