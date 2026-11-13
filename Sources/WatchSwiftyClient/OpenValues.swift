/// String values from the API that a newer server may extend (a new streaming service, a new import status).
/// The generated client uses these open types instead of closed enums (`typeOverrides` in
/// `openapi-generator-config.yaml`), so an unknown value decodes, can be shown neutrally and is sent back unchanged.
public protocol OpenStringValue: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
    /// The values this client was generated with, in the order of the API description.
    static var known: [Self] { get }
}

extension OpenStringValue {
    public var isKnown: Bool { Self.known.contains(self) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Schema `Service`: the streaming service of a watch.
public struct ServiceValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let netflix = Self(rawValue: "netflix")
    public static let primeVideo = Self(rawValue: "prime_video")
    public static let disneyPlus = Self(rawValue: "disney_plus")
    public static let appleTV = Self(rawValue: "apple_tv")
    public static let hboMax = Self(rawValue: "hbo_max")
    public static let paramountPlus = Self(rawValue: "paramount_plus")
    public static let wow = Self(rawValue: "wow")
    public static let cinema = Self(rawValue: "cinema")
    public static let purchased = Self(rawValue: "purchased")
    public static let other = Self(rawValue: "other")
    public static let known: [Self] = [.netflix, .primeVideo, .disneyPlus, .appleTV, .hboMax, .paramountPlus, .wow,
                                       .cinema, .purchased, .other]
}

/// Schema `WatchOrigin`: whether a watch was entered by hand or imported.
public struct WatchOriginValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let manual = Self(rawValue: "manual")
    public static let `import` = Self(rawValue: "import")
    public static let known: [Self] = [.manual, .import]
}

/// Schema `MappingStatus`: state of a Netflix title mapping.
public struct MappingStatusValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending = Self(rawValue: "pending")
    public static let auto = Self(rawValue: "auto")
    public static let confirmed = Self(rawValue: "confirmed")
    public static let review = Self(rawValue: "review")
    public static let ignored = Self(rawValue: "ignored")
    public static let known: [Self] = [.pending, .auto, .confirmed, .review, .ignored]
}

/// Schema `FilmStatus`: state of a film list entry.
public struct FilmStatusValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let pending = Self(rawValue: "pending")
    public static let imported = Self(rawValue: "imported")
    public static let review = Self(rawValue: "review")
    public static let notFound = Self(rawValue: "not_found")
    public static let skipped = Self(rawValue: "skipped")
    public static let known: [Self] = [.pending, .imported, .review, .notFound, .skipped]
}

/// Schema `DeviceKind`: device token from the browser login or created by hand.
public struct DeviceKindValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let device = Self(rawValue: "device")
    public static let manual = Self(rawValue: "manual")
    public static let known: [Self] = [.device, .manual]
}

/// How notifications are sent (`NotifyChannel`).
public struct NotifyChannelValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mail = Self(rawValue: "mail")
    public static let webhook = Self(rawValue: "webhook")
    public static let known: [Self] = [.mail, .webhook]
}

/// Schema `Genre`: one genre list for series and movies.
public struct GenreValue: OpenStringValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let action = Self(rawValue: "action")
    public static let adventure = Self(rawValue: "adventure")
    public static let animation = Self(rawValue: "animation")
    public static let comedy = Self(rawValue: "comedy")
    public static let crime = Self(rawValue: "crime")
    public static let documentary = Self(rawValue: "documentary")
    public static let drama = Self(rawValue: "drama")
    public static let family = Self(rawValue: "family")
    public static let fantasy = Self(rawValue: "fantasy")
    public static let history = Self(rawValue: "history")
    public static let horror = Self(rawValue: "horror")
    public static let music = Self(rawValue: "music")
    public static let mystery = Self(rawValue: "mystery")
    public static let romance = Self(rawValue: "romance")
    public static let scienceFiction = Self(rawValue: "science_fiction")
    public static let tvMovie = Self(rawValue: "tv_movie")
    public static let thriller = Self(rawValue: "thriller")
    public static let war = Self(rawValue: "war")
    public static let western = Self(rawValue: "western")
    public static let kids = Self(rawValue: "kids")
    public static let news = Self(rawValue: "news")
    public static let reality = Self(rawValue: "reality")
    public static let soap = Self(rawValue: "soap")
    public static let talk = Self(rawValue: "talk")
    public static let politics = Self(rawValue: "politics")
    public static let known: [Self] = [.action, .adventure, .animation, .comedy, .crime, .documentary, .drama,
                                       .family, .fantasy, .history, .horror, .music, .mystery, .romance,
                                       .scienceFiction, .tvMovie, .thriller, .war, .western, .kids, .news,
                                       .reality, .soap, .talk, .politics]
}
