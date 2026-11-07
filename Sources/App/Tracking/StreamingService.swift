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
