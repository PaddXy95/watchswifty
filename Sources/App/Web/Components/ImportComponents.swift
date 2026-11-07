import Elementary
import ElementaryHTMX2
import Foundation

struct ImportProgress: HTML {
    let isRunning: Bool
    let pendingRows: Int
    let waitingForReview: Int
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
struct CandidateList: HTML {
    let mappingID: UUID
    let results: [TMDBSearchResult]
    let action: String   // "accept" | "change"
    let target: String

    var body: some HTML {
        div(.class("candidates")) {
            if results.isEmpty {
                p(.class("muted")) { "Keine Treffer." }
            }
            for result in results {
                button(.class("candidate"), .hx.post("/import/mappings/\(mappingID.uuidString)/\(action)"),
                       .hx.vals(#"{"kind":"\#(result.kind.rawValue)","tmdbID":"\#(result.id)"}"#),
                       .hx.target(target), .hx.swap(.outerHTML)) {
                    Poster(path: result.posterPath, alt: result.name)
                    span {
                        result.name
                        if let year = result.year { " (\(year))" }
                        " · "
                        span(.class("candidate-action")) { "Übernehmen" }
                    }
                }
            }
        }
    }
}

struct CandidateSearch: HTML {
    let mappingID: UUID
    let mode: String
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

struct ReviewItem {
    let mapping: NetflixMapping
    let rowCount: Int
}

struct MappingReviewItem: HTML {
    let item: ReviewItem

    var body: some HTML {
        let id = item.mapping.id!
        article(.class("mapping-review card"), .id("mapping-\(id.uuidString)")) {
            div(.class("card-body")) {
                h3 { item.mapping.netflixName }
                p(.class("muted")) { "\(item.rowCount) Zeilen · \(item.mapping.titleKind == .tv ? "Serie" : "Film")" }
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

struct UnmatchedItem {
    let row: NetflixRow
    /// The row's name is mapped to a series, so it can be assigned to one of its episodes.
    let canAssign: Bool
}

struct UnmatchedRowItem: HTML {
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

struct MappingListItem: HTML {
    let mapping: NetflixMapping
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
struct AssignForm: HTML {
    let rowID: UUID
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
