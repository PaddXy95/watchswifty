import Fluent
import Foundation

/// An entry of a user's „Später ansehen“ list (spec `2026-11-21-watch-later-availability-design.md` §1). Counts as using
/// the title (`titleUsers`). `baselined == false` means: the offers present at the next successful fetch are recorded as
/// already known instead of being reported (§4.3).
final class WatchLaterEntry: Model, @unchecked Sendable {
    static let schema = "watch_later"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "title_id") var title: Title
    @Field(key: "added_at") var addedAt: Date
    /// Day of adding (`YYYY-MM-DD`): imported watches before it do not remove the entry.
    @Field(key: "added_on") var addedOn: String
    @Field(key: "baselined") var baselined: Bool

    /// Creates an empty model (required by Fluent).
    init() {}

    /// Creates a list entry.
    /// - Parameters:
    ///   - userID: The list's owner.
    ///   - titleID: The title put on the list.
    ///   - addedAt: When it was added.
    ///   - addedOn: The day it was added (`YYYY-MM-DD`).
    ///   - baselined: Whether the present offers were already recorded as known.
    init(userID: UUID, titleID: UUID, addedAt: Date, addedOn: String, baselined: Bool = false) {
        self.$user.id = userID
        self.$title.id = titleID
        self.addedAt = addedAt
        self.addedOn = addedOn
        self.baselined = baselined
    }
}

/// When a title's offers were last fetched and for which countries. Does not count as using the title.
final class TitleAvailability: Model, @unchecked Sendable {
    static let schema = "title_availability"

    @ID(key: .id) var id: UUID?
    @Parent(key: "title_id") var title: Title
    @Field(key: "fetched_at") var fetchedAt: Date
    /// Countries stored at that fetch, sorted and comma separated („AT,DE“).
    @Field(key: "regions") var regions: String
    @OptionalField(key: "tmdb_link") var tmdbLink: String?

    /// `regions` as a list of country codes.
    var regionList: [String] { regions.split(separator: ",").map(String.init) }

    /// Creates an empty model (required by Fluent).
    init() {}

    /// Creates the fetch state of a title.
    /// - Parameters:
    ///   - titleID: The title.
    ///   - fetchedAt: When the offers were fetched.
    ///   - regions: The countries stored at that fetch (stored sorted).
    ///   - tmdbLink: TMDB's watch page link for the title, if any.
    init(titleID: UUID, fetchedAt: Date, regions: [String], tmdbLink: String?) {
        self.$title.id = titleID
        self.fetchedAt = fetchedAt
        self.regions = regions.sorted().joined(separator: ",")
        self.tmdbLink = tmdbLink
    }
}

/// One offer of a title in one country (TMDB watch providers, data by JustWatch). Does not count as using the title.
final class TitleProvider: Model, @unchecked Sendable {
    static let schema = "title_providers"

    @ID(key: .id) var id: UUID?
    @Parent(key: "title_id") var title: Title
    @Field(key: "region") var region: String
    @Field(key: "provider_id") var providerID: Int
    @Field(key: "provider_name") var providerName: String
    @OptionalField(key: "logo_path") var logoPath: String?
    @Field(key: "kind") var kind: String
    @Field(key: "display_priority") var displayPriority: Int

    /// `kind` as ``OfferKind``; nil for an unknown stored value.
    var offerKind: OfferKind? { OfferKind(rawValue: kind) }

    /// Creates an empty model (required by Fluent).
    init() {}

    /// Creates the stored row of one TMDB offer.
    /// - Parameters:
    ///   - titleID: The title.
    ///   - region: The country code of the offer.
    ///   - offer: The offer as returned by TMDB.
    init(titleID: UUID, region: String, offer: TMDBOffer) {
        self.$title.id = titleID
        self.region = region
        self.providerID = offer.providerID
        self.providerName = offer.name
        self.logoPath = offer.logoPath
        self.kind = offer.kind.rawValue
        self.displayPriority = offer.displayPriority
    }
}

/// A streaming service the user has (Konto → Streamingdienste); TMDB provider id.
final class UserStreamingService: Model, @unchecked Sendable {
    static let schema = "user_streaming_services"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "provider_id") var providerID: Int

    /// Creates an empty model (required by Fluent).
    init() {}

    /// Creates a streaming service entry.
    /// - Parameters:
    ///   - userID: The user.
    ///   - providerID: The service's TMDB provider id.
    init(userID: UUID, providerID: Int) {
        self.$user.id = userID
        self.providerID = providerID
    }
}

/// State of a known offer for one user (§1, §4.3).
enum NoticeState: String, Codable, Sendable {
    /// Was already there when the entry was added or services, country or switch changed: never reported.
    case baseline
    /// Appeared while notifications were off: not reported, but „neu seit“ on the list.
    case skipped
    /// Appeared with notifications on: waits for the next digest.
    case pending
    /// Reported.
    case sent
}

/// A user's known offer of a title on their list. Does not count as using the title.
final class AvailabilityNotice: Model, @unchecked Sendable {
    static let schema = "availability_notices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Parent(key: "title_id") var title: Title
    @Field(key: "provider_id") var providerID: Int
    @Field(key: "noticed_at") var noticedAt: Date
    @Field(key: "state") var state: String

    /// `state` as ``NoticeState``; nil for an unknown stored value.
    var noticeState: NoticeState? { NoticeState(rawValue: state) }

    /// Creates an empty model (required by Fluent).
    init() {}

    /// Creates a known offer.
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The title on the user's list.
    ///   - providerID: The service's TMDB provider id.
    ///   - noticedAt: When the offer was first recorded.
    ///   - state: Whether it is a baseline, skipped, pending or sent.
    init(userID: UUID, titleID: UUID, providerID: Int, noticedAt: Date, state: NoticeState) {
        self.$user.id = userID
        self.$title.id = titleID
        self.providerID = providerID
        self.noticedAt = noticedAt
        self.state = state.rawValue
    }
}
