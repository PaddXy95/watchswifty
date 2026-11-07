import Foundation

/// Lowercased, diacritics folded (ß → ss), dashes/colons → spaces, other punctuation dropped,
/// trailing "(n)" removed, whitespace collapsed.
func normalizeTitle(_ s: String) -> String {
    var text = s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS")
    text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
    if let range = text.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
        text.removeSubrange(range)
    }
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
