import Elementary

struct ImportPage: HTML {
    let nav: NavContext
    let summary: ImportSummary?
    let error: String?

    var body: some HTML {
        PageLayout(title: "Import", nav: nav) {
            h1 { "Import" }
            section(.class("import-upload")) {
                h2 { "Upload" }
                p(.class("muted")) {
                    "Netflix: Profil → Konto → Wiedergabeaktivität → „Alle herunterladen“. Die Datei heißt NetflixViewingHistory.csv."
                }
                Messages(error: error, notice: summary.map {
                    "\($0.new) neu, \($0.known) bereits bekannt, \($0.skipped) übersprungen (leerer Titel)"
                })
                form(.method(.post), .action("/import"), .custom(name: "enctype", value: "multipart/form-data")) {
                    input(.type(.file), .name("file"), .custom(name: "accept", value: ".csv,text/csv"), .required)
                    button(.type(.submit), .class("primary")) { "Hochladen" }
                }
            }
        }
    }
}
