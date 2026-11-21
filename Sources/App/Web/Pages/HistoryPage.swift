import Elementary

/// „Verlauf“ (history) page at `/history`, a tab of „Bibliothek“ (library): a table of the user's viewings.
///
/// Shows „Noch keine Einträge.“ (no entries yet) instead of the table when there are none.
struct HistoryPage: HTML {
    let nav: NavContext
    /// First page of rows; when there are more, `HistoryRows` adds the „Mehr laden“ (load more) row.
    let rows: HistoryRows

    var body: some HTML {
        PageLayout(title: "Verlauf", nav: nav) {
            SectionTabs.library(.history)
            h1 { "Verlauf" }
            if rows.rows.isEmpty {
                p(.class("muted")) { "Noch keine Einträge." }
            } else {
                table(.class("history-table")) {
                    thead { tr { th { "Datum" }; th { "Titel" }; th { "Dienst" }; th { "Herkunft" }; th { "" } } }
                    tbody { rows }
                }
            }
        }
    }
}
