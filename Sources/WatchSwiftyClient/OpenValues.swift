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
