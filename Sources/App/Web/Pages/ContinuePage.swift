import Elementary

struct ContinuePage: HTML {
    let nav: NavContext
    let cards: [ContinueCard]

    var body: some HTML {
        PageLayout(title: "Weiterschauen", nav: nav) {
            h1 { "Weiterschauen" }
            if cards.isEmpty {
                p(.class("muted")) { "Noch nichts zum Weiterschauen." }
            }
            div(.class("card-list")) {
                for card in cards { ContinueCardView(card: card) }
            }
        }
    }
}
