import Elementary

/// „Weiterschauen“ (continue watching) home page at `/`: a card per series to continue, with the new and upcoming
/// episodes box beside it.
///
/// By default only series watched in the last three months are shown; a link switches to `/?all=1` and back.
struct ContinuePage: HTML {
    let nav: NavContext
    /// Series to continue, in display order.
    let cards: [ContinueCard]
    /// Number of older series left out; above 0 the page links to `/?all=1` to show them.
    var hiddenCount = 0
    /// `?all=1` is active: shows the link back to „Nur letzte 3 Monate“ (only the last 3 months).
    var showingAll = false
    /// New episodes of followed series for the aside box.
    var newEpisodes: [NewEpisodesNote] = []
    /// Upcoming episodes for the aside box.
    var upcoming: [UpcomingNote] = []

    /// Whether the `NewEpisodesBox` aside is shown (two-column layout `with-aside`).
    private var hasAside: Bool { !newEpisodes.isEmpty || !upcoming.isEmpty }

    var body: some HTML {
        PageLayout(title: "Weiterschauen", nav: nav) {
            h1 { "Weiterschauen" }
            div(.class(hasAside ? "home with-aside" : "home")) {
                if hasAside { NewEpisodesBox(notes: newEpisodes, upcoming: upcoming) }
                div(.class("home-main")) {
                    if cards.isEmpty {
                        p(.class("muted")) { "Noch nichts zum Weiterschauen." }
                    }
                    div(.class("card-list")) {
                        for card in cards { ContinueCardView(card: card) }
                    }
            if hiddenCount > 0 {
                p(.class("muted more-link")) {
                    a(.href("/?all=1")) { hiddenCount == 1 ? "1 ältere Serie anzeigen" : "\(hiddenCount) ältere Serien anzeigen" }
                }
            } else if showingAll {
                p(.class("muted more-link")) { a(.href("/")) { "Nur letzte 3 Monate" } }
            }
                }
            }
        }
    }
}
