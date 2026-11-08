import Foundation

enum StreamingService: String, Codable, Sendable, CaseIterable {
    case netflix
    case primeVideo = "prime_video"
    case disneyPlus = "disney_plus"
    case appleTV = "apple_tv"
    case hboMax = "hbo_max"
    case paramountPlus = "paramount_plus"
    case wow
    case cinema
    case purchased
    case other

    var label: String {
        switch self {
        case .netflix: "Netflix"
        case .primeVideo: "Prime Video"
        case .disneyPlus: "Disney+"
        case .appleTV: "Apple TV+"
        case .hboMax: "HBO Max"
        case .paramountPlus: "Paramount+"
        case .wow: "WOW"
        case .cinema: "Kino"
        case .purchased: "Gekauft"
        case .other: "Sonstiges"
        }
    }
}

enum WatchOrigin: String, Codable, Sendable {
    case manual
    case `import`
}

/// Button on the „Weiterschauen“ card that opens the series at the service.
struct WatchLink: Sendable, Equatable {
    let label: String
    let url: String
}

extension StreamingService {
    /// Search on the service when its web search can be opened with the title (checked 2026-11: Netflix, Prime Video
    /// on amazon.de, Apple TV+, Paramount+); otherwise the service's start page. Nil for Kino, Gekauft, Sonstiges.
    func watchLink(for title: String) -> WatchLink? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
        switch self {
        case .netflix: return WatchLink(label: "Auf Netflix suchen", url: "https://www.netflix.com/search?q=\(query)")
        case .primeVideo: return WatchLink(label: "Auf Prime Video suchen", url: "https://www.amazon.de/s?k=\(query)&i=instant-video")
        case .appleTV: return WatchLink(label: "Auf Apple TV+ suchen", url: "https://tv.apple.com/de/search?term=\(query)")
        case .paramountPlus: return WatchLink(label: "Auf Paramount+ suchen", url: "https://www.paramountplus.com/de/search/?q=\(query)")
        // No public web search without login: open the service.
        case .disneyPlus: return WatchLink(label: "Disney+ öffnen", url: "https://www.disneyplus.com/")
        case .hboMax: return WatchLink(label: "HBO Max öffnen", url: "https://play.hbomax.com/")
        case .wow: return WatchLink(label: "WOW öffnen", url: "https://www.wowtv.de/")
        case .cinema, .purchased, .other: return nil
        }
    }
}
