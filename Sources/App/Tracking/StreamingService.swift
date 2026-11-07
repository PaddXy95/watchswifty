enum StreamingService: String, Codable, Sendable, CaseIterable {
    case netflix
    case primeVideo = "prime_video"
    case disneyPlus = "disney_plus"
    case appleTV = "apple_tv"
    case cinema
    case other

    var label: String {
        switch self {
        case .netflix: "Netflix"
        case .primeVideo: "Prime Video"
        case .disneyPlus: "Disney+"
        case .appleTV: "Apple TV+"
        case .cinema: "Kino"
        case .other: "Sonstiges"
        }
    }
}

enum WatchOrigin: String, Codable, Sendable {
    case manual
    case `import`
}
