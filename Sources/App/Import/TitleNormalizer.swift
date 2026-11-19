import Foundation

/// Longest title kept from an import file; real titles are far shorter, and matching cost grows with the length
/// (security audit F05).
let maxImportTitleLength = 500

/// Lowercased, diacritics folded (ß → ss), dashes/colons → spaces, other punctuation dropped,
/// trailing "(n)" removed, whitespace collapsed.
func normalizeTitle(_ s: String) -> String {
    var text = s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS")
    text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
    text = removingTrailingNumber(text)
    var out = ""
    for scalar in text.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        } else if CharacterSet.whitespaces.contains(scalar) || "–—-:/".unicodeScalars.contains(scalar) {
            out.append(" ")
        }
    }
    return out.split(separator: " ").joined(separator: " ")
}

/// Removes a trailing "(n)" and the whitespace around it, like the regex `\s*\(\d+\)\s*$` but in linear time: the
/// regex backtracks quadratically over long whitespace runs (security audit F05).
func removingTrailingNumber(_ text: String) -> String {
    func isDigit(_ c: Character) -> Bool { c.unicodeScalars.count == 1 && c.unicodeScalars.first!.properties.generalCategory == .decimalNumber }
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
    guard end > text.startIndex, text[text.index(before: end)] == ")" else { return text }
    var start = text.index(before: end)
    var digits = 0
    while start > text.startIndex, isDigit(text[text.index(before: start)]) {
        start = text.index(before: start)
        digits += 1
    }
    guard digits > 0, start > text.startIndex, text[text.index(before: start)] == "(" else { return text }
    start = text.index(before: start)
    while start > text.startIndex, text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
    return String(text[..<start])
}

/// Levenshtein distance over Unicode scalars.
func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

func similarity(_ a: String, _ b: String) -> Double {
    let longest = max(a.unicodeScalars.count, b.unicodeScalars.count)
    guard longest > 0 else { return 1 }
    return 1 - Double(levenshtein(a, b)) / Double(longest)
}
