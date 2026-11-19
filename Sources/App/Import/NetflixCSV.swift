import Foundation

struct NetflixCSVRow: Sendable, Equatable {
    let title: String
    /// ISO day `yyyy-MM-dd`.
    let day: String
    /// Stable identity across re-exports: `day#occurrence#title`.
    let fingerprint: String
}

struct NetflixCSVResult: Sendable, Equatable {
    let rows: [NetflixCSVRow]
    let skippedBlank: Int
}

enum NetflixCSVError: Error, Equatable {
    case notNetflixHistory
    case invalidDate(line: Int, value: String)
    /// The upload would store more rows than one user may keep (`ImportService.maxStoredRows`).
    case tooManyRows(limit: Int)
}

/// Parses Netflix's "Wiedergabeaktivität" export (`Title,Date`, dates `M/D/YY`).
func parseNetflixCSV(_ text: String) throws -> NetflixCSVResult {
    var input = text
    if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
    // German Excel/Numbers re-saves CSVs with ";" as the separator.
    let firstLine = input.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
    let delimiter: Character = firstLine.contains(";") && !firstLine.contains(",") ? ";" : ","
    let records = splitCSVRecords(input, delimiter: delimiter)

    guard let header = records.first, header.fields.map({ $0.trimmingCharacters(in: .whitespaces) }) == ["Title", "Date"] else {
        throw NetflixCSVError.notNetflixHistory
    }

    var rows: [NetflixCSVRow] = []
    var skipped = 0
    var occurrences: [String: Int] = [:]
    for record in records.dropFirst() {
        if record.fields.count == 1 && record.fields[0].trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard record.fields.count >= 2 else { throw NetflixCSVError.invalidDate(line: record.line, value: "") }
        let title = String(record.fields[0].prefix(maxImportTitleLength))
        let rawDate = record.fields[1].trimmingCharacters(in: .whitespaces)
        guard let day = netflixDay(rawDate) else { throw NetflixCSVError.invalidDate(line: record.line, value: rawDate) }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix(":") {
            skipped += 1
            continue
        }
        let key = "\(day)#\(title)"
        let occurrence = occurrences[key, default: 0]
        occurrences[key] = occurrence + 1
        rows.append(NetflixCSVRow(title: title, day: day, fingerprint: "\(day)#\(occurrence)#\(title)"))
    }
    return NetflixCSVResult(rows: rows, skippedBlank: skipped)
}

/// Netflix's `M/D/YY` (also `M/D/YYYY`), plus what spreadsheet round-trips produce:
/// German `D.M.YYYY` / `D.M.YY` and ISO `YYYY-MM-DD` → `yyyy-MM-dd`.
func netflixDay(_ raw: String) -> String? {
    func numbers(_ separator: Character) -> [Substring]? {
        let parts = raw.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts
    }
    func year(_ part: Substring) -> Int? {
        guard part.count == 2 || part.count == 4, let value = Int(part) else { return nil }
        return part.count == 2 ? 2000 + value : value
    }
    let ymd: (Int, Int, Int)?
    if let p = numbers("/"), let y = year(p[2]), let m = Int(p[0]), let d = Int(p[1]) {
        ymd = (y, m, d)
    } else if let p = numbers("."), let y = year(p[2]), let d = Int(p[0]), let m = Int(p[1]) {
        ymd = (y, m, d)
    } else if let p = numbers("-"), p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) {
        ymd = (y, m, d)
    } else {
        ymd = nil
    }
    guard let (y, m, d) = ymd else { return nil }
    let iso = CalendarDay.format(year: y, month: m, day: d)
    return CalendarDay.isValid(iso) ? iso : nil
}

struct CSVRecord {
    let line: Int
    let fields: [String]
}

/// Minimal RFC 4180 splitter: quoted fields, `""` escapes, commas/newlines inside quotes, LF or CRLF.
func splitCSVRecords(_ text: String, delimiter: Character) -> [CSVRecord] {
    var records: [CSVRecord] = []
    var fields: [String] = []
    var field = ""
    var inQuotes = false
    var line = 1
    var recordLine = 1
    var chars = Array(text)
    chars.append("\n")
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if inQuotes {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    field.append("\"")
                    i += 1
                } else {
                    inQuotes = false
                }
            } else {
                if c == "\n" || c == "\r\n" { line += 1 }
                field.append(c)
            }
        } else if c == "\"" {
            inQuotes = true
        } else if c == delimiter {
            fields.append(field)
            field = ""
        } else if c == "\n" || c == "\r\n" || c == "\r" {
            fields.append(field)
            if !(fields.count == 1 && fields[0].isEmpty) {
                records.append(CSVRecord(line: recordLine, fields: fields))
            }
            fields = []
            field = ""
            line += 1
            recordLine = line
        } else {
            field.append(c)
        }
        i += 1
    }
    return records
}
