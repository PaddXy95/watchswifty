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
}

/// Parses Netflix's "Wiedergabeaktivität" export (`Title,Date`, dates `M/D/YY`).
func parseNetflixCSV(_ text: String) throws -> NetflixCSVResult {
    var input = text
    if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
    let records = splitCSVRecords(input)

    guard let header = records.first, header.fields.map({ $0.trimmingCharacters(in: .whitespaces) }) == ["Title", "Date"] else {
        throw NetflixCSVError.notNetflixHistory
    }

    var rows: [NetflixCSVRow] = []
    var skipped = 0
    var occurrences: [String: Int] = [:]
    for record in records.dropFirst() {
        if record.fields.count == 1 && record.fields[0].trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard record.fields.count >= 2 else { throw NetflixCSVError.invalidDate(line: record.line, value: "") }
        let title = record.fields[0]
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

/// `M/D/YY` (or `M/D/YYYY`) → `yyyy-MM-dd`.
func netflixDay(_ raw: String) -> String? {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          let month = Int(parts[0]), let day = Int(parts[1]), var year = Int(parts[2]),
          parts[2].count == 2 || parts[2].count == 4 else { return nil }
    if parts[2].count == 2 { year += 2000 }
    let iso = CalendarDay.format(year: year, month: month, day: day)
    return CalendarDay.isValid(iso) ? iso : nil
}

private struct CSVRecord {
    let line: Int
    let fields: [String]
}

/// Minimal RFC 4180 splitter: quoted fields, `""` escapes, commas/newlines inside quotes, LF or CRLF.
private func splitCSVRecords(_ text: String) -> [CSVRecord] {
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
        } else if c == "," {
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
