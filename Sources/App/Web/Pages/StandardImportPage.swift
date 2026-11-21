import Elementary
import ElementaryHTMX2
import Foundation

/// „Aus anderen Trackern importieren“: upload of the standard CSV and review of unclear titles.
struct StandardImportPage: HTML {
    let nav: NavContext
    /// All entries of the last upload.
    let entries: [ImportEntry]
    /// Error of a failed upload.
    let error: String?
    /// Result notice of an upload just processed.
    let notice: String?

    /// Entries waiting for a decision (to review or not found at TMDB).
    private var open: [ImportEntry] { entries.filter { [.review, .notFound].contains($0.entryStatus) } }
    /// Entries already imported, listed folded at the end.
    private var imported: [ImportEntry] { entries.filter { $0.entryStatus == .imported } }

    var body: some HTML {
        PageLayout(title: "Aus anderen Trackern importieren", nav: nav) {
            SectionTabs.account(.importing)
            h1 { "Aus anderen Trackern importieren" }
            p(.class("muted")) { a(.href("/import")) { "← Zurück zum Netflix-Import" } }
            section {
                p {
                    "CSV im WatchSwifty-Format – zum Beispiel aus Letterboxd, IMDb oder Trakt umgebaut. "
                    "Pflicht sind die Spalten type und title, alles andere ist optional."
                }
                p {
                    a(.href("/import/watchswifty-import-example.csv"), .custom(name: "download", value: "")) { "Beispieldatei herunterladen" }
                    " · "
                    DocsLink(page: "import.md#other-trackers-standard-csv", label: "Format und Umbau-Hinweise")
                }
                ul(.class("muted")) {
                    li { "Jede movie- und episode-Zeile wird eine Sichtung." }
                    li { "Eine series-Zeile nimmt die Serie mit Bewertung und Kommentar in die Bibliothek auf." }
                    li { "Ein neuer Upload ersetzt diese Liste; schon vorhandene Sichtungen werden nicht doppelt angelegt." }
                }
                Messages(error: error, notice: notice)
                form(.method(.post), .action("/import/standard"), .custom(name: "enctype", value: "multipart/form-data")) {
                    input(.type(.file), .name("file"), .custom(name: "accept", value: ".csv,text/csv"), .required)
                    button(.type(.submit), .class("primary")) { "Hochladen" }
                }
            }
            if !entries.isEmpty {
                ImportStatusBox(entries: entries)
                section {
                    h2 { "Zu prüfen" }
                    if open.isEmpty { p(.class("muted")) { "Nichts zu prüfen." } }
                    div(.class("card-list")) {
                        for entry in open { ImportEntryCard(entry: entry) }
                    }
                }
                if !imported.isEmpty {
                    details(.class("film-imported")) {
                        summary { "Übernommene Titel anzeigen (\(imported.count))" }
                        div(.class("card-list")) {
                            for entry in imported { ImportEntryCard(entry: entry) }
                        }
                    }
                }
            }
        }
    }
}

/// Counts; polls while entries are still waiting for TMDB.
struct ImportStatusBox: HTML {
    /// All entries of the last upload.
    let entries: [ImportEntry]

    /// Number of entries with a status.
    /// - Parameter status: The status to count.
    /// - Returns: The count.
    private func count(_ status: ImportEntryStatus) -> Int { entries.filter { $0.entryStatus == status }.count }
    /// Error of the first pending entry that failed (e.g. TMDB unreachable); while set, polling stops and
    /// „Erneut versuchen“ (retry) is offered.
    private var pendingError: String? { entries.first { $0.entryStatus == .pending && $0.error != nil }?.error }

    var body: some HTML {
        let pending = count(.pending)
        div(.id("import-status"), .class("film-status")) {
            p {
                "\(count(.imported)) übernommen · \(count(.review)) zu prüfen · \(count(.notFound)) nicht gefunden · "
                "\(count(.skipped)) übersprungen"
                if pending > 0 { " · \(pending) in Arbeit" }
            }
            if let pendingError {
                p(.class("error"), .custom(name: "role", value: "alert")) { pendingError }
                button(.hx.post("/import/standard/retry"), .hx.target("#import-status"), .hx.swap(.outerHTML)) { "Erneut versuchen" }
            }
        }
        .attributes(.hx.get("/import/standard/status?polling=1"), .custom(name: "hx-trigger", value: "every 2s"), .hx.swap(.outerHTML),
                    when: pending > 0 && pendingError == nil)
    }
}

/// Card of one standard-import entry (`#import-<id>`): title, kind, number of viewings and rating, then by status a link
/// to the imported title, a waiting note, or, for entries to review, TMDB candidates with a search field and
/// „Überspringen“ (skip).
///
/// Accept, search and skip target the card (`closest .film-entry`) and replace it (outerHTML) with the updated card the
/// server returns.
struct ImportEntryCard: HTML {
    /// The entry to show.
    let entry: ImportEntry

    /// Base path of the entry's actions.
    private var path: String { "/import/standard/\(entry.id?.uuidString ?? "")" }

    var body: some HTML {
        let watches = entry.watchList.count
        let isSeries = entry.titleKind == .tv
        div(.class("card film-entry"), .id("import-\(entry.id?.uuidString ?? "")")) {
            div(.class("film-entry-body")) {
                p {
                    strong { entry.title }
                    if let year = entry.year { " (\(year))" }
                    span(.class("muted")) {
                        " · \(isSeries ? "Serie" : "Film")"
                        " · \(watches == 1 ? "1 Sichtung" : "\(watches) Sichtungen")"
                        if let rating = entry.rating { " · ★ \(rating)" }
                    }
                }
                switch entry.entryStatus {
                case .imported:
                    p(.class("notice")) {
                        "✓ übernommen · "
                        if let tmdbID = entry.tmdbID {
                            if isSeries {
                                a(.href("/tv/\(tmdbID)")) { "Serie öffnen" }
                            } else {
                                a(.href("/movie/\(tmdbID)")) { "Film öffnen" }
                            }
                        }
                    }
                    if entry.missingEpisodes > 0 {
                        p(.class("muted")) {
                            entry.missingEpisodes == 1 ? "1 Episode nicht gefunden" : "\(entry.missingEpisodes) Episoden nicht gefunden"
                        }
                    }
                case .skipped:
                    p(.class("muted")) { "übersprungen" }
                case .pending:
                    p(.class("muted")) { entry.error ?? "wartet auf TMDB …" }
                case .review, .notFound:
                    if entry.entryStatus == .notFound { p(.class("muted")) { "Bei TMDB nicht gefunden." } }
                    div(.class("candidates")) {
                        for result in entry.candidateList {
                            CandidateRow(result: result, popoverID: CandidateRow.newPopoverID(), acceptURL: "\(path)/accept",
                                         vals: #"{"tmdbID":"\#(result.id)"}"#, target: "closest .film-entry")
                        }
                    }
                    form(.class("inline-form"), .hx.post("\(path)/search"), .hx.target("closest .film-entry"), .hx.swap(.outerHTML)) {
                        input(.type(.search), .name("q"), .value(entry.title), .custom(name: "aria-label", value: "Anderer Suchbegriff"))
                        button(.type(.submit)) { "Suchen" }
                    }
                    button(.hx.post("\(path)/skip"), .hx.target("closest .film-entry"), .hx.swap(.outerHTML)) { "Überspringen" }
                }
            }
        }
    }
}
