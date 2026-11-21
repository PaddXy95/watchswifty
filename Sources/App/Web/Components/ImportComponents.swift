import Elementary
import ElementaryHTMX2
import Foundation

/// Progress of the Netflix import's title matching on the import page (`#import-progress`).
///
/// While a run is going it polls `/import/progress?polling=1` every 2 s; it also reloads on the `importChanged` event,
/// which decisions send via `HX-Trigger`. It shows the pending rows (while running), rows waiting for review and the
/// last error, and offers „Erneut versuchen“ (retry) when no run is going but there was an error or rows are pending.
struct ImportProgress: HTML {
    /// Whether a matching run is going.
    let isRunning: Bool
    /// Rows still to be matched (without those waiting for review).
    let pendingRows: Int
    /// Rows whose mapping waits for the user's review.
    let waitingForReview: Int
    /// The last matching error for this user, if any.
    let lastError: String?
    /// The page was polling and the run is over: offer a reload instead of forcing one.
    var finished = false

    var body: some HTML {
        div(.id("import-progress"), .class("import-progress"),
            .hx.get(isRunning ? "/import/progress?polling=1" : "/import/progress"),
            .custom(name: "hx-trigger", value: isRunning ? "every 2s, importChanged from:body" : "importChanged from:body"),
            .hx.swap(.outerHTML)) {
            if isRunning {
                p(.class("notice")) { "Zuordnung läuft … (\(pendingRows) Zeilen ausstehend)" }
            }
            if finished && !isRunning {
                p(.class("notice")) {
                    "Zuordnung abgeschlossen. "
                    a(.href("/import")) { "Seite aktualisieren" }
                }
            }
            if waitingForReview > 0 {
                p { "\(waitingForReview) Zeilen warten auf Prüfung" }
            }
            if let lastError {
                p(.class("error")) { lastError }
            }
            if !isRunning && (lastError != nil || pendingRows > 0) {
                button(.hx.post("/import/retry"), .hx.target("#import-progress"), .hx.swap(.outerHTML)) { "Erneut versuchen" }
            }
        }
    }
}

/// German label of a mapping status, shown as the badge in the mapping list.
/// - Parameter status: The mapping status.
/// - Returns: E.g. „automatisch“ (automatic) or „zu prüfen“ (to review).
func mappingStatusLabel(_ status: MappingStatus) -> String {
    switch status {
    case .auto: "automatisch"
    case .confirmed: "bestätigt"
    case .ignored: "ignoriert"
    case .pending: "ausstehend"
    case .review: "zu prüfen"
    }
}

/// TMDB candidates for a mapping; clicking one accepts (review) or changes (mapping list) it.
///
/// Each ``CandidateRow`` posts to `/import/mappings/<id>/<action>`. Also the response of the own TMDB search.
struct CandidateList: HTML {
    /// ID of the mapping the candidates are for.
    let mappingID: UUID
    /// TMDB search results to offer.
    let results: [TMDBSearchResult]
    /// Decision endpoint: `accept` (review) or `change` (mapping list).
    let action: String   // "accept" | "change"
    /// htmx target the decision response replaces, e.g. `closest .mapping-review`.
    let target: String

    var body: some HTML {
        div(.class("candidates")) {
            if results.isEmpty {
                p(.class("muted")) { "Keine Treffer." }
            }
            for result in results {
                CandidateRow(result: result, popoverID: CandidateRow.newPopoverID(),
                             acceptURL: "/import/mappings/\(mappingID.uuidString)/\(action)",
                             vals: #"{"kind":"\#(result.kind.rawValue)","tmdbID":"\#(result.id)"}"#, target: target)
            }
        }
    }
}

/// One TMDB candidate: poster (click → large popover), name (year), TMDB link and „Übernehmen“.
///
/// The poster button opens a native popover (`popovertarget`); „Übernehmen“ (take over) posts to `acceptURL` and
/// replaces `target` with the response.
struct CandidateRow: HTML {
    /// The TMDB search result.
    let result: TMDBSearchResult
    /// Unique on the page: the same candidate can appear in several lists (review, own search, film list).
    let popoverID: String
    /// URL „Übernehmen“ posts to.
    let acceptURL: String
    /// `hx-vals` JSON sent with „Übernehmen“.
    let vals: String
    /// htmx target (CSS selector) the response replaces.
    let target: String

    /// A fresh id for the poster popover.
    /// - Returns: `poster-<random UUID>`.
    static func newPopoverID() -> String { "poster-\(UUID().uuidString.lowercased())" }

    var body: some HTML {
        div(.class("candidate")) {
            if result.posterPath != nil {
                button(.type(.button), .class("poster-button"), .custom(name: "popovertarget", value: popoverID),
                       .custom(name: "aria-label", value: "Poster von \(result.name) vergrößern")) {
                    Poster(path: result.posterPath, alt: result.name, displayWidth: 40)
                }
                div(.id(popoverID), .custom(name: "popover", value: ""), .class("poster-popover")) {
                    Poster(path: result.posterPath, alt: result.name, displayWidth: 342)
                }
            } else {
                Poster(path: nil, alt: result.name, displayWidth: 40)
            }
            span(.class("candidate-name")) {
                result.name
                if let year = result.year { " (\(year))" }
            }
            a(.href("https://www.themoviedb.org/\(result.kind.rawValue)/\(result.id)"), .target(.blank),
              .custom(name: "rel", value: "noopener noreferrer"), .class("candidate-link")) { "TMDB ↗" }
            button(.class("primary"), .hx.post(acceptURL), .hx.vals(vals), .hx.target(target), .hx.swap(.outerHTML)) { "Übernehmen" }
        }
    }
}

/// „Bei TMDB suchen“ (search TMDB) field for a mapping, with an empty results container below it.
///
/// Typing (debounced 300 ms) fetches `/import/mappings/<id>/search?mode=<mode>` and puts the ``CandidateList`` into
/// `#<mode>-candidates-<mapping id>`.
struct CandidateSearch: HTML {
    /// ID of the mapping to search for.
    let mappingID: UUID
    /// `accept` (review) or `change` (mapping list); passed to the search, it selects the results' endpoint.
    let mode: String
    /// Not used in the markup: the server derives the candidates' target from `mode`.
    let target: String

    var body: some HTML {
        let resultsID = "\(mode)-candidates-\(mappingID.uuidString)"
        input(.type(.search), .name("q"), .custom(name: "placeholder", value: "Bei TMDB suchen"),
              .custom(name: "aria-label", value: "Bei TMDB suchen"),
              .hx.get("/import/mappings/\(mappingID.uuidString)/search?mode=\(mode)"),
              .custom(name: "hx-trigger", value: "input changed delay:300ms, search"), .hx.target("#\(resultsID)"))
        div(.id(resultsID)) {}
    }
}

/// View model of one mapping waiting for review, with its open Netflix rows.
struct ReviewItem {
    /// Maximum number of rows listed under „Zeilen anzeigen“ (show rows).
    static let rowLimit = 20

    /// The mapping to review.
    let mapping: NetflixMapping
    /// Open rows of the mapping, newest first.
    let rows: [NetflixRow]

    /// Creates a review item, sorting the rows newest first (same day: by raw title).
    /// - Parameters:
    ///   - mapping: The mapping to review.
    ///   - rows: Its open rows, in any order.
    init(mapping: NetflixMapping, rows: [NetflixRow]) {
        self.mapping = mapping
        self.rows = rows.sorted { ($0.watchedOn, $1.rawTitle) > ($1.watchedOn, $0.rawTitle) }
    }

    /// Number of open rows.
    var rowCount: Int { rows.count }
    /// Earliest viewing day (`YYYY-MM-DD`); empty without rows.
    var firstDay: String { rows.last?.watchedOn ?? "" }
    /// Latest viewing day (`YYYY-MM-DD`); empty without rows.
    var lastDay: String { rows.first?.watchedOn ?? "" }
    /// The newest rows, at most ``rowLimit``.
    var shownRows: ArraySlice<NetflixRow> { rows.prefix(Self.rowLimit) }

    /// „gesehen am 06.11.2026“ or „gesehen 02.03.2025 – 06.11.2026“.
    var watchedText: String {
        firstDay == lastDay
            ? "gesehen am \(CalendarDay.display(lastDay))"
            : "gesehen \(CalendarDay.display(firstDay)) – \(CalendarDay.display(lastDay))"
    }
}

/// Review card for one Netflix name (`#mapping-<id>`): row count and dates, the rows, TMDB candidates, an own search
/// („Eigene Suche“) and „Ignorieren“ (ignore); every decision replaces the closest `.mapping-review`.
struct MappingReviewItem: HTML {
    /// The mapping and its open rows.
    let item: ReviewItem

    var body: some HTML {
        let id = item.mapping.id!
        article(.class("mapping-review card"), .id("mapping-\(id.uuidString)")) {
            div(.class("card-body")) {
                h3 { item.mapping.netflixName }
                p(.class("muted")) {
                    "\(item.rowCount) Zeilen · \(item.mapping.titleKind == .tv ? "Serie" : "Film")"
                    if !item.rows.isEmpty { " · \(item.watchedText)" }
                }
                if !item.rows.isEmpty {
                    details(.class("review-rows")) {
                        summary { "Zeilen anzeigen" }
                        ul {
                            for row in item.shownRows { li { "\(row.rawTitle) · \(CalendarDay.display(row.watchedOn))" } }
                            if item.rowCount > item.shownRows.count {
                                li(.class("muted")) { "… und \(item.rowCount - item.shownRows.count) weitere" }
                            }
                        }
                    }
                }
                CandidateList(mappingID: id, results: item.mapping.candidateResults, action: "accept", target: "closest .mapping-review")
                details {
                    summary { "Eigene Suche" }
                    CandidateSearch(mappingID: id, mode: "accept", target: "closest .mapping-review")
                }
                button(.hx.post("/import/mappings/\(id.uuidString)/ignore"), .hx.target("closest .mapping-review"),
                       .hx.swap(.outerHTML)) { "Ignorieren" }
            }
        }
    }
}

/// View model of a Netflix row that could not be matched to an episode or movie.
struct UnmatchedItem {
    /// The unmatched row.
    let row: NetflixRow
    /// The row's name is mapped to a series, so it can be assigned to one of its episodes.
    let canAssign: Bool
}

/// Card for one unmatched Netflix row (`#row-<id>`) with „Ignorieren“ (ignore) and, if possible, „Folge wählen“
/// (choose episode).
///
/// „Folge wählen“ loads the ``AssignForm`` from `/import/rows/<id>/options` into its `.assign-slot`; ignoring or
/// assigning replaces the closest `.unmatched-row`.
struct UnmatchedRowItem: HTML {
    /// The row and whether it can be assigned.
    let item: UnmatchedItem

    var body: some HTML {
        let id = item.row.id!.uuidString
        article(.class("unmatched-row card"), .id("row-\(id)")) {
            div(.class("card-body")) {
                strong { item.row.rawTitle }
                span(.class("muted")) { " · \(CalendarDay.display(item.row.watchedOn))" }
                if item.canAssign {
                    // Episode lists of long series are large: loaded only when needed.
                    span(.class("assign-slot")) {
                        button(.hx.get("/import/rows/\(id)/options"), .hx.target("closest .assign-slot"), .hx.swap(.innerHTML)) { "Folge wählen" }
                    }
                }
                button(.hx.post("/import/rows/\(id)/ignore"), .hx.target("closest .unmatched-row"), .hx.swap(.outerHTML)) { "Ignorieren" }
            }
        }
    }
}

/// Entry of the mapping list (`#mapping-item-<id>`): Netflix name → title, status badge, „Ändern“ (change, with a TMDB
/// search) and „Zurücksetzen“ (reset, after a confirmation); responses replace the closest `.mapping-item`.
struct MappingListItem: HTML {
    /// The mapping to show.
    let mapping: NetflixMapping
    /// Name of the mapped title, or `nil` (shown as „–“).
    let titleName: String?

    var body: some HTML {
        let id = mapping.id!
        li(.class("mapping-item"), .id("mapping-item-\(id.uuidString)")) {
            strong { mapping.netflixName }
            " → "
            titleName ?? "–"
            " "
            span(.class("badge")) { mappingStatusLabel(mapping.mappingStatus) }
            details(.class("mapping-change")) {
                summary { "Ändern" }
                CandidateSearch(mappingID: id, mode: "change", target: "closest .mapping-item")
            }
            button(.hx.post("/import/mappings/\(id.uuidString)/reset"),
                   .hx.confirm("Zuordnung zurücksetzen? Die daraus importierten Sichtungen werden gelöscht."),
                   .hx.target("closest .mapping-item"), .hx.swap(.outerHTML)) { "Zurücksetzen" }
        }
    }
}

/// Episode picker for one unmatched row, fetched on demand.
///
/// Posts the chosen episode to `/import/rows/<id>/assign` and replaces the closest `.unmatched-row`.
struct AssignForm: HTML {
    /// ID of the Netflix row to assign.
    let rowID: UUID
    /// Episodes of the mapped series, grouped by season in the select.
    let episodes: [Episode]

    var body: some HTML {
        form(.class("inline-form"), .hx.post("/import/rows/\(rowID.uuidString)/assign"), .hx.target("closest .unmatched-row"),
             .hx.swap(.outerHTML)) {
            select(.name("episodeID"), .custom(name: "aria-label", value: "Folge auswählen")) {
                for (season, seasonEpisodes) in Dictionary(grouping: episodes, by: \.season).sorted(by: { $0.key < $1.key }) {
                    optgroup(.custom(name: "label", value: season == 0 ? "Specials" : "Staffel \(season)")) {
                        for episode in seasonEpisodes {
                            option(.value(episode.id!.uuidString)) { "\(episode.code) · \(episode.name)" }
                        }
                    }
                }
            }
            button(.type(.submit)) { "Zuordnen" }
        }
    }
}
