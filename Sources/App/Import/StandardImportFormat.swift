import Foundation

/// Row kind of the standard import CSV (spec `2026-11-19-standard-import-design.md` §1).
enum StandardRowType: String, Sendable {
    case movie, episode, series
}

/// One valid line of a standard import file.
struct StandardImportRow: Sendable, Equatable {
    let type: StandardRowType
    let title: String
    let year: Int?
    let tmdbID: Int?
    let imdbID: String?
    let season: Int?
    let episode: Int?
    /// ISO day, nil when missing or unreadable.
    let day: String?
    let service: StreamingService?
    let rating: Int?
    let comment: String?
}

/// Result of parsing a standard import file.
struct StandardImportFile: Sendable, Equatable {
    let rows: [StandardImportRow]
    /// Lines with an unknown type, without a title or (episodes) without season/episode number.
    let skippedRows: Int
}

/// Why a standard import file could not be parsed.
enum StandardImportError: Error, Equatable {
    /// No line contains both the `type` and `title` columns.
    case noHeader
}

/// Parses a standard import file: the header is the first line with the columns `type` and `title` (any case, any
/// order, extra columns ignored); `;` or `,` as separator.
///
/// `;` is tried first, then `,`. Empty lines are ignored; lines with an unknown type, no title, or (episodes) no
/// season/episode number are counted as skipped. Unreadable optional values (year, IDs, day, rating) become nil.
/// - Parameter text: The file content.
/// - Returns: The valid rows and the number of skipped lines.
/// - Throws: `StandardImportError.noHeader` when no header line is found.
func parseStandardImport(_ text: String) throws -> StandardImportFile {
    var input = text
    if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
    /// The value without surrounding whitespace and newlines.
    func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Index of the first record that contains the `type` and `title` columns.
    func headerIndex(_ records: [CSVRecord]) -> Int? {
        records.firstIndex { record in
            let names = Set(record.fields.map { clean($0).lowercased() })
            return names.contains("type") && names.contains("title")
        }
    }

    var records = splitCSVRecords(input, delimiter: ";")
    var start = headerIndex(records)
    if start == nil {
        records = splitCSVRecords(input, delimiter: ",")
        start = headerIndex(records)
    }
    guard let start else { throw StandardImportError.noHeader }

    let header = records[start].fields.map { clean($0).lowercased() }
    /// Index of a header column, or nil when the file lacks it.
    func column(_ name: String) -> Int? { header.firstIndex(of: name) }
    let columns = (type: column("type"), title: column("title"), year: column("year"), tmdb: column("tmdb_id"),
                   imdb: column("imdb_id"), season: column("season"), episode: column("episode"),
                   day: column("watched_on"), service: column("service"), rating: column("rating"),
                   comment: column("comment"))

    var rows: [StandardImportRow] = []
    var skipped = 0
    for record in records[(start + 1)...] {
        /// The cleaned field at a column index, or an empty string when the column or field is missing.
        func value(_ index: Int?) -> String {
            guard let index, index < record.fields.count else { return "" }
            return clean(record.fields[index])
        }
        if record.fields.allSatisfy({ clean($0).isEmpty }) { continue }
        let title = String(value(columns.title).prefix(maxImportTitleLength))
        guard let type = StandardRowType(rawValue: value(columns.type).lowercased()), !title.isEmpty else {
            skipped += 1
            continue
        }
        let season = Int(value(columns.season)).flatMap { $0 >= 0 ? $0 : nil }
        let episode = Int(value(columns.episode)).flatMap { $0 >= 0 ? $0 : nil }
        if type == .episode && (season == nil || episode == nil) {
            skipped += 1
            continue
        }
        let imdb = value(columns.imdb)
        rows.append(StandardImportRow(
            type: type,
            title: title,
            year: Int(value(columns.year)).flatMap { (1800...9999).contains($0) ? $0 : nil },
            tmdbID: Int(value(columns.tmdb)).flatMap { $0 > 0 ? $0 : nil },
            imdbID: imdb.wholeMatch(of: /tt\d+/) != nil ? imdb : nil,
            season: type == .episode ? season : nil,
            episode: type == .episode ? episode : nil,
            day: importDay(value(columns.day)),
            service: StreamingService(importValue: value(columns.service)),
            rating: importRating(value(columns.rating)),
            comment: value(columns.comment).isEmpty ? nil : value(columns.comment)
        ))
    }
    return StandardImportFile(rows: rows, skippedRows: skipped)
}

/// `YYYY-MM-DD` (also with a time after `T` or a space), `DD.MM.YYYY`, `D.M.YYYY`, `M/D/YY` → ISO day.
///
/// - Parameter raw: The date as written in the file.
/// - Returns: The ISO day, or nil when unreadable.
func importDay(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text.prefixMatch(of: /\d{4}-\d{2}-\d{2}[T ]/) != nil {
        return netflixDay(String(text.prefix(10)))
    }
    return netflixDay(text)
}

/// 1–10; decimals (`7.5`, `7,5`) rounded, values above 10 capped, 0, negative, non-finite or empty = no rating.
///
/// - Parameter raw: The rating as written in the file.
/// - Returns: A rating 1–10, or nil for no rating.
func importRating(_ raw: String) -> Int? {
    guard let value = Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
          value.isFinite, value > 0 else { return nil }
    // Clamp before converting: `Int(Double)` traps outside Int's range.
    return Int(min(10, max(1, value.rounded())))
}

extension StreamingService {
    /// The service key (`prime_video`) or a name as people write it; unknown → `.other`, empty → nil.
    ///
    /// - Parameter importValue: The `service` column value.
    init?(importValue: String) {
        let text = importValue.trimmingCharacters(in: .whitespaces)
        if let service = StreamingService(rawValue: text.lowercased()) {
            self = service
        } else {
            self.init(label: text)
        }
    }
}

/// One viewing of an import entry: a movie viewing has no season/episode.
struct ImportWatch: Codable, Sendable, Equatable {
    let season: Int?
    let episode: Int?
    let day: String?
    let service: StreamingService?
}

/// One title of the file with all its rows (spec §2).
struct ImportDraft: Sendable, Equatable {
    let kind: TitleKind
    let title: String
    let year: Int?
    /// `tmdb_id` from the file (checked against TMDB during matching).
    let tmdbHint: Int?
    let imdbID: String?
    let watches: [ImportWatch]
    let rating: Int?
    let comment: String?
}

/// Groups rows into one draft per title, in order of first appearance. Episode rows ignore `imdb_id` for the key (it
/// may be the episode's own id) but keep it as a hint.
///
/// Rows are keyed by TMDB ID, else IMDb ID (not for episodes), else normalized title and year. The draft takes kind,
/// title and year from the first row, the first IDs, the last rating, and distinct comments joined (capped at
/// `WatchService.maxCommentLength`); `series` rows add no viewing.
/// - Parameter rows: The parsed rows in file order.
/// - Returns: One draft per title.
func groupStandardImport(_ rows: [StandardImportRow]) -> [ImportDraft] {
    var order: [String] = []
    var groups: [String: [StandardImportRow]] = [:]
    for row in rows {
        let kind = row.type == .movie ? "movie" : "tv"
        let key: String
        if let tmdb = row.tmdbID {
            key = "\(kind)#t\(tmdb)"
        } else if row.type != .episode, let imdb = row.imdbID {
            key = "\(kind)#i\(imdb)"
        } else {
            key = "\(kind)#n\(normalizeTitle(row.title))#\(row.year.map(String.init) ?? "")"
        }
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(row)
    }
    return order.map { key in
        let rows = groups[key]!
        var comments: [String] = []
        for comment in rows.compactMap(\.comment) where !comments.contains(comment) { comments.append(comment) }
        let comment = comments.joined(separator: "\n\n")
        return ImportDraft(
            kind: rows[0].type == .movie ? .movie : .tv,
            title: rows[0].title,
            year: rows[0].year,
            tmdbHint: rows.lazy.compactMap(\.tmdbID).first,
            imdbID: rows.lazy.compactMap(\.imdbID).first,
            watches: rows.filter { $0.type != .series }
                .map { ImportWatch(season: $0.season, episode: $0.episode, day: $0.day, service: $0.service) },
            rating: rows.compactMap(\.rating).last,
            comment: comment.isEmpty ? nil : String(comment.prefix(WatchService.maxCommentLength))
        )
    }
}
