import Foundation

/// One line of a personal film list (Numbers/Excel export, see the UI-round spec „Filmliste“).
struct FilmListRow: Sendable, Equatable {
    let title: String
    let year: Int?
    /// ISO day, nil when missing or unreadable.
    let day: String?
    let service: StreamingService?
    let rating: Int?
    /// Names from the checked „Mit …“ columns.
    let companions: [String]
    let culprit: String?
    let remark: String?
}

enum FilmListError: Error, Equatable {
    case notFilmList
}

struct FilmWatch: Sendable, Equatable, Codable {
    let day: String?
    let service: StreamingService?
}

/// One film with all its viewings from the list.
struct FilmListDraft: Sendable, Equatable {
    let title: String
    let year: Int?
    let watches: [FilmWatch]
    let rating: Int?
    let comment: String?
}

/// Parses the list: the header row holds „Filmname“; rows without a film name (group rows „5 ★“) are skipped.
func parseFilmList(_ text: String) throws -> [FilmListRow] {
    var input = text
    if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
    let firstLine = input.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
    let delimiter: Character = firstLine.contains(";") ? ";" : ","
    let records = splitCSVRecords(input, delimiter: delimiter)
    func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    guard let headerIndex = records.firstIndex(where: { $0.fields.contains { clean($0) == "Filmname" } }) else {
        throw FilmListError.notFilmList
    }
    let header = records[headerIndex].fields.map(clean)
    func column(_ name: String) -> Int? { header.firstIndex(of: name) }
    let titleColumn = column("Filmname")!
    let companionColumns = header.enumerated().compactMap { index, name -> (Int, String)? in
        guard name.hasPrefix("Mit "), name.count > 4 else { return nil }
        return (index, String(name.dropFirst(4)))
    }

    return records[(headerIndex + 1)...].compactMap { record in
        func value(_ index: Int?) -> String {
            guard let index, index < record.fields.count else { return "" }
            return clean(record.fields[index])
        }
        let title = String(value(titleColumn).prefix(maxImportTitleLength))
        guard !title.isEmpty else { return nil }
        let checked: Set<String> = ["wahr", "true", "ja", "x", "1"]
        return FilmListRow(
            title: title,
            year: Int(value(column("Erscheinungsjahr"))).flatMap { (1800...9999).contains($0) ? $0 : nil },
            day: germanDay(value(column("Datum"))),
            service: StreamingService(label: value(column("Streamingdienst"))),
            rating: filmRating(detail: value(column("Detail")), stars: value(column("Bewertung"))),
            companions: companionColumns.filter { checked.contains(value($0.0).lowercased()) }.map(\.1),
            culprit: value(column("Übeltäter")).nilIfEmpty,
            remark: value(column("Bemerkung")).nilIfEmpty
        )
    }
}

/// „Mo., 1. Jan. 2024“, „15. Juni 2025“, „18. Sept. 2026“, plus the numeric formats of `netflixDay`.
func germanDay(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if let day = netflixDay(text) { return day }
    guard let match = text.firstMatch(of: /(\d{1,2})\.\s*([A-Za-zÄäÖöÜü]+)\.?\s+(\d{4})/),
          let day = Int(match.1), let year = Int(match.3) else { return nil }
    let months = ["jan", "feb", "mär", "apr", "mai", "jun", "jul", "aug", "sep", "okt", "nov", "dez"]
    var name = match.2.lowercased()
    if name.hasPrefix("mar") { name = "mär" + name.dropFirst(3) }
    guard let index = months.firstIndex(where: { name.hasPrefix($0) }) else { return nil }
    let iso = CalendarDay.format(year: year, month: index + 1, day: day)
    return CalendarDay.isValid(iso) ? iso : nil
}

/// „Detail“ 0–100 → 1–10 (rounded, at least 1); without it, stars (0,5–5) × 2. Non-finite values count as missing.
func filmRating(detail: String, stars: String) -> Int? {
    func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }
    let raw: Double
    if let detail = number(detail) {
        raw = detail / 10
    } else if let stars = number(stars) {
        raw = stars * 2
    } else {
        return nil
    }
    // Clamp before converting: `Int(Double)` traps outside Int's range.
    return Int(min(10, max(1, raw.rounded())))
}

extension StreamingService {
    /// Maps a service name as people write it („Amazon Prime“, „WowTV“, „Gekauft“); unknown names → `.other`.
    init?(label: String) {
        let key = label.lowercased().filter { $0.isLetter }
        guard !key.isEmpty else { return nil }
        let table: [(String, StreamingService)] = [
            ("netflix", .netflix), ("amazon", .primeVideo), ("prime", .primeVideo), ("disney", .disneyPlus),
            ("apple", .appleTV), ("hbo", .hboMax), ("max", .hboMax), ("paramount", .paramountPlus), ("wow", .wow),
            ("sky", .wow), ("kino", .cinema), ("cinema", .cinema), ("gekauft", .purchased), ("kauf", .purchased),
        ]
        self = table.first { key.hasPrefix($0.0) }?.1 ?? .other
    }
}

/// Merges repeated films (same normalized title and year) in list order; one viewing per row.
func groupFilmList(_ rows: [FilmListRow]) -> [FilmListDraft] {
    var order: [String] = []
    var groups: [String: [FilmListRow]] = [:]
    for row in rows {
        let key = "\(normalizeTitle(row.title))#\(row.year.map(String.init) ?? "")"
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(row)
    }
    return order.map { key in
        let rows = groups[key]!
        let latest = rows.enumerated().max { a, b in (a.element.day ?? "", a.offset) < (b.element.day ?? "", b.offset) }!.element
        let lines: [String] = rows.compactMap { row in
            let parts = commentParts(row)
            guard !parts.isEmpty else { return nil }
            guard rows.count > 1 else { return parts.joined(separator: "\n") }
            let when = row.day.map(CalendarDay.display) ?? "ohne Datum"
            return "\(when): " + parts.joined(separator: " · ")
        }
        let comment = lines.joined(separator: "\n")
        return FilmListDraft(title: rows[0].title, year: rows[0].year,
                             watches: rows.map { FilmWatch(day: $0.day, service: $0.service) },
                             rating: latest.rating ?? rows.compactMap(\.rating).last,
                             comment: comment.isEmpty ? nil : String(comment.prefix(WatchService.maxCommentLength)))
    }
}

private func commentParts(_ row: FilmListRow) -> [String] {
    var parts: [String] = []
    if !row.companions.isEmpty {
        let names = row.companions.count == 1 ? row.companions[0]
            : row.companions.dropLast().joined(separator: ", ") + " und " + row.companions.last!
        parts.append("Mit \(names)")
    }
    if let culprit = row.culprit { parts.append("Übeltäter: \(culprit)") }
    if let remark = row.remark { parts.append(remark) }
    return parts
}

enum FilmChoice: Equatable {
    case match(TMDBSearchResult)
    case review([TMDBSearchResult])
    case notFound
}

/// Distance between two years that never traps, also for entries stored before years were range-checked.
private func yearGap(_ a: Int, _ b: Int) -> Int {
    let (difference, overflow) = a.subtractingReportingOverflow(b)
    return overflow || difference == .min ? .max : abs(difference)
}

/// Picks the TMDB movie for a list entry: an exact title among results within ±1 year of the list's year, or the only
/// result in that range, is taken automatically; anything else goes to review (at most 5 candidates).
func chooseFilm(query: String, year: Int?, results: [TMDBSearchResult]) -> FilmChoice {
    guard !results.isEmpty else { return .notFound }
    let wanted = normalizeTitle(query)
    func isExact(_ result: TMDBSearchResult) -> Bool {
        normalizeTitle(result.name) == wanted || result.originalName.map(normalizeTitle) == wanted
    }
    let inRange = year.map { year in
        results.filter { result in result.year.map { yearGap($0, year) <= 1 } ?? false }
            .sorted { yearGap($0.year ?? 0, year) < yearGap($1.year ?? 0, year) }
    } ?? results
    let exact = inRange.filter(isExact)
    func distance(_ result: TMDBSearchResult) -> Int { year.map { yearGap(result.year ?? 0, $0) } ?? 0 }
    // Several exact titles: the one closest to the list's year wins, unless two are equally close.
    if exact.count == 1 || (exact.count > 1 && year != nil && distance(exact[0]) < distance(exact[1])) { return .match(exact[0]) }
    if inRange.count == 1 { return .match(inRange[0]) }
    return .review(Array((inRange.isEmpty ? results : inRange).prefix(5)))
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
