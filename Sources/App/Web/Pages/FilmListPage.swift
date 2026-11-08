import Elementary
import ElementaryHTMX2
import Foundation

struct FilmListPage: HTML {
    let nav: NavContext
    let entries: [FilmListEntry]
    let error: String?
    let notice: String?

    private var open: [FilmListEntry] { entries.filter { [.review, .notFound].contains($0.filmStatus) } }
    private var imported: [FilmListEntry] { entries.filter { $0.filmStatus == .imported } }

    var body: some HTML {
        PageLayout(title: "Filmliste importieren", nav: nav) {
            h1 { "Filmliste importieren" }
            p(.class("muted")) { a(.href("/import")) { "← Zurück zum Netflix-Import" } }
            section {
                p {
                    "Eigene Filmliste als CSV (z. B. aus Numbers: Ablage → Exportieren → CSV). Erkannt werden die Spalten "
                    "Filmname, Erscheinungsjahr, Datum, „Mit …“, Streamingdienst, Übeltäter, Bewertung, Detail und Bemerkung; "
                    "Zeilen ohne Filmname (z. B. „5 ★“) werden übersprungen."
                }
                ul(.class("muted")) {
                    li { "„Mit …“, Übeltäter und Bemerkung kommen in den Kommentar zum Film." }
                    li { "Detail (0–100) wird zur Bewertung 1–10; ohne Detail zählen die Sterne × 2." }
                    li { "Steht ein Film mehrfach drin, wird jede Zeile eine Sichtung mit ihrem Datum." }
                    li { "Ein neuer Upload ersetzt diese Liste; schon vorhandene Sichtungen werden nicht doppelt angelegt." }
                }
                Messages(error: error, notice: notice)
                form(.method(.post), .action("/import/films"), .custom(name: "enctype", value: "multipart/form-data")) {
                    input(.type(.file), .name("file"), .custom(name: "accept", value: ".csv,text/csv"), .required)
                    button(.type(.submit), .class("primary")) { "Hochladen" }
                }
            }
            if !entries.isEmpty {
                FilmListStatusBox(entries: entries)
                section {
                    h2 { "Zu prüfen" }
                    if open.isEmpty { p(.class("muted")) { "Nichts zu prüfen." } }
                    div(.class("card-list")) {
                        for entry in open { FilmEntryCard(entry: entry) }
                    }
                }
                if !imported.isEmpty {
                    details(.class("film-imported")) {
                        summary { "Übernommene Filme anzeigen (\(imported.count))" }
                        div(.class("card-list")) {
                            for entry in imported { FilmEntryCard(entry: entry) }
                        }
                    }
                }
            }
        }
    }
}

/// Counts; polls while entries are still waiting for TMDB.
struct FilmListStatusBox: HTML {
    let entries: [FilmListEntry]

    private func count(_ status: FilmListStatus) -> Int { entries.filter { $0.filmStatus == status }.count }
    private var pendingError: String? { entries.first { $0.filmStatus == .pending && $0.error != nil }?.error }

    var body: some HTML {
        let pending = count(.pending)
        div(.id("film-status"), .class("film-status")) {
            p {
                "\(count(.imported)) übernommen · \(count(.review)) zu prüfen · \(count(.notFound)) nicht gefunden · "
                "\(count(.skipped)) übersprungen"
                if pending > 0 { " · \(pending) in Arbeit" }
            }
            if let pendingError {
                p(.class("error"), .custom(name: "role", value: "alert")) { pendingError }
                button(.hx.post("/import/films/retry"), .hx.target("#film-status"), .hx.swap(.outerHTML)) { "Erneut versuchen" }
            }
        }
        .attributes(.hx.get("/import/films/status?polling=1"), .custom(name: "hx-trigger", value: "every 2s"), .hx.swap(.outerHTML),
                    when: pending > 0 && pendingError == nil)
    }
}

struct FilmEntryCard: HTML {
    let entry: FilmListEntry

    private var path: String { "/import/films/\(entry.id?.uuidString ?? "")" }

    var body: some HTML {
        let watches = entry.watchList
        div(.class("card film-entry"), .id("film-\(entry.id?.uuidString ?? "")")) {
            div(.class("film-entry-body")) {
                p {
                    strong { entry.title }
                    if let year = entry.year { " (\(year))" }
                    span(.class("muted")) {
                        " · \(watches.count == 1 ? "1 Sichtung" : "\(watches.count) Sichtungen")"
                        if let rating = entry.rating { " · ★ \(rating)" }
                    }
                }
                switch entry.filmStatus {
                case .imported:
                    p(.class("notice")) {
                        "✓ übernommen · "
                        if let tmdbID = entry.tmdbID { a(.href("/movie/\(tmdbID)")) { "Film öffnen" } }
                    }
                case .skipped:
                    p(.class("muted")) { "übersprungen" }
                case .pending:
                    p(.class("muted")) { entry.error ?? "wartet auf TMDB …" }
                case .review, .notFound:
                    if entry.filmStatus == .notFound { p(.class("muted")) { "Bei TMDB nicht gefunden." } }
                    div(.class("candidates")) {
                        for result in entry.candidateList {
                            button(.class("candidate"), .hx.post("\(path)/accept"), .hx.vals(#"{"tmdbID":"\#(result.id)"}"#),
                                   .hx.target("closest .film-entry"), .hx.swap(.outerHTML)) {
                                Poster(path: result.posterPath, alt: result.name, displayWidth: 40)
                                span { "\(result.name)\(result.year.map { " (\($0))" } ?? "") · Übernehmen" }
                            }
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
