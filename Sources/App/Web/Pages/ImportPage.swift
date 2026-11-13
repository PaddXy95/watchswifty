import Elementary

struct ImportState {
    let progress: ImportProgress
    let review: [ReviewItem]
    let unmatched: [UnmatchedItem]
    let unmatchedTotal: Int
    let mappings: [(NetflixMapping, String?)]
    let mappingFilter: String
}

struct ImportPage: HTML {
    let navContext: NavContext
    let summary: ImportSummary?
    let error: String?
    let state: ImportState

    private let filters = [("all", "Alle"), ("auto", "automatisch"), ("confirmed", "bestätigt"), ("ignored", "ignoriert")]

    var body: some HTML {
        PageLayout(title: "Import", nav: navContext) {
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
                    "Eigene Filmliste aus Numbers oder Excel? "
                    a(.href("/import/films")) { "Filmliste importieren" }
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
