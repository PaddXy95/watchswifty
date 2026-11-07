import Elementary

struct ContinuePage: HTML {
    let nav: NavContext
    let cards: [ContinueCard]
    var hiddenCount = 0
    var showingAll = false

    var body: some HTML {
        PageLayout(title: "Weiterschauen", nav: nav) {
            h1 { "Weiterschauen" }
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
