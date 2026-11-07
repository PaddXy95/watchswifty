import Elementary

struct HistoryPage: HTML {
    let nav: NavContext
    let rows: HistoryRows

    var body: some HTML {
        PageLayout(title: "Verlauf", nav: nav) {
            h1 { "Verlauf" }
            if rows.rows.isEmpty {
                p(.class("muted")) { "Noch keine Einträge." }
            } else {
                table {
                    thead { tr { th { "Datum" }; th { "Titel" }; th { "Dienst" }; th { "Herkunft" }; th { "" } } }
                    tbody { rows }
                }
            }
        }
    }
}
