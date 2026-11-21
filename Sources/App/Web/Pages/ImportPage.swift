import Elementary

/// Everything the Netflix import page shows besides the result of an upload (built by `ImportStateService`).
struct ImportState {
    /// Matching progress, rendered in the upload section.
    let progress: ImportProgress
    /// Netflix names without a clear match that wait for a decision („Zu prüfen“, to review), with their pending rows.
    let review: [ReviewItem]
    /// The newest rows without a match („Nicht zugeordnet“, unmatched), limited in number.
    let unmatched: [UnmatchedItem]
    /// Total number of unmatched rows; the page notes how many are not listed.
    let unmatchedTotal: Int
    /// Mappings for the active filter with the matched title's name (nil when there is none).
    let mappings: [(NetflixMapping, String?)]
    /// Active mapping filter: `all`, `auto`, `confirmed` or `ignored`.
    let mappingFilter: String
}

/// Netflix import page at `/import`, the „Import“ tab of „Konto“ (account): CSV upload with matching progress, the rows
/// to review, unmatched rows and the filterable list of mappings (filter links `/import?status=…`).
struct ImportPage: HTML {
    let navContext: NavContext
    /// Counts of an upload just processed, shown as a notice.
    let summary: ImportSummary?
    /// Error of a failed upload.
    let error: String?
    let state: ImportState

    /// Mapping filters as (query value, German label).
    private let filters = [("all", "Alle"), ("auto", "automatisch"), ("confirmed", "bestätigt"), ("ignored", "ignoriert")]

    var body: some HTML {
        PageLayout(title: "Import", nav: navContext) {
            SectionTabs.account(.importing)
            h1 { "Import" }
            section(.class("import-upload")) {
                h2 { "Upload" }
                p(.class("muted")) {
                    "Netflix im Browser: Konto → Einstellungen → Titelverlauf → ganz unten „Alle herunterladen“. Die Datei heißt NetflixViewingHistory.csv."
                }
                Messages(error: error, notice: summary.map {
                    "\($0.new) neu, \($0.known) bereits bekannt, \($0.skipped) übersprungen (leerer Titel)"
                })
                form(.method(.post), .action("/import"), .custom(name: "enctype", value: "multipart/form-data")) {
                    input(.type(.file), .name("file"), .custom(name: "accept", value: ".csv,text/csv"), .required)
                    button(.type(.submit), .class("primary")) { "Hochladen" }
                }
                state.progress
                p(.class("muted")) {
                    "Verlauf aus einem anderen Tracker? "
                    a(.href("/import/standard")) { "Aus anderen Trackern importieren" }
                }
            }
            section {
                h2 { "Zu prüfen" }
                if state.review.isEmpty { p(.class("muted")) { "Nichts zu prüfen." } }
                div(.class("card-list")) {
                    for item in state.review { MappingReviewItem(item: item) }
                }
            }
            section {
                h2 { "Nicht zugeordnet" }
                if state.unmatched.isEmpty { p(.class("muted")) { "Alle Zeilen sind zugeordnet." } }
                div(.class("card-list")) {
                    for item in state.unmatched { UnmatchedRowItem(item: item) }
                }
                if state.unmatchedTotal > state.unmatched.count {
                    p(.class("muted")) { "… und \(state.unmatchedTotal - state.unmatched.count) weitere" }
                }
            }
            section {
                h2 { "Zuordnungen" }
                nav(.class("filter-bar"), .custom(name: "aria-label", value: "Zuordnungen filtern")) {
                    for (key, label) in filters {
                        a(.href("/import?status=\(key)")) { label }
                            .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: key == state.mappingFilter)
                    }
                }
                ul(.class("mapping-list")) {
                    for (mapping, titleName) in state.mappings { MappingListItem(mapping: mapping, titleName: titleName) }
                }
            }
        }
    }
}
