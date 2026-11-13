import Foundation
import Testing
import WatchSwiftyClient

@Suite struct OpenValueTests {
    @Test func unknownServiceDecodes() throws {
        let json = #"{"id":"0F2B4D63-8E57-4E0A-9C5B-3B1E2D4F5A6B","kind":"tv","tmdbId":1,"title":"X","service":"crunchyroll","origin":"manual"}"#
        let item = try JSONDecoder().decode(Components.Schemas.HistoryItem.self, from: Data(json.utf8))
        #expect(item.service?.rawValue == "crunchyroll")
        #expect(item.service?.isKnown == false)
    }

    @Test func unknownOriginDecodes() throws {
        let json = #"{"id":"0F2B4D63-8E57-4E0A-9C5B-3B1E2D4F5A6B","kind":"tv","tmdbId":1,"title":"X","origin":"trakt"}"#
        let item = try JSONDecoder().decode(Components.Schemas.HistoryItem.self, from: Data(json.utf8))
        #expect(item.origin.rawValue == "trakt")
    }

    @Test func watchEditRoundTripsUnknownService() throws {
        let edit = Components.Schemas.WatchEdit(day: "2026-11-07", service: ServiceValue(rawValue: "crunchyroll"))
        let json = String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)
        #expect(json.contains(#""service":"crunchyroll""#))
    }

    /// A newer app talking to a 0.4.0 server: fields added later must not be required.
    @Test func olderServerResponsesDecode() throws {
        let entry = #"{"kind":"tv","tmdbId":1,"name":"X","hidden":false}"#
        _ = try JSONDecoder().decode(Components.Schemas.LibraryEntry.self, from: Data(entry.utf8))
        let movie = #"{"tmdbId":603,"name":"Matrix","links":{"tmdb":"t","imdb":"i","rottenTomatoes":"r"},"watches":[]}"#
        _ = try JSONDecoder().decode(Components.Schemas.MovieDetail.self, from: Data(movie.utf8))
        let review = #"{"id":"0F2B4D63-8E57-4E0A-9C5B-3B1E2D4F5A6B","netflixName":"X","kind":"tv","rowCount":1,"candidates":[]}"#
        _ = try JSONDecoder().decode(Components.Schemas.MappingReview.self, from: Data(review.utf8))
    }

    @Test func knownValuesMatchSpec() {
        #expect(ServiceValue.known.map(\.rawValue) == ["netflix", "prime_video", "disney_plus", "apple_tv", "hbo_max",
                                                        "paramount_plus", "wow", "cinema", "purchased", "other"])
        #expect(WatchOriginValue.known.map(\.rawValue) == ["manual", "import"])
        #expect(MappingStatusValue.known.map(\.rawValue) == ["pending", "auto", "confirmed", "review", "ignored"])
        #expect(FilmStatusValue.known.map(\.rawValue) == ["pending", "imported", "review", "not_found", "skipped"])
        #expect(DeviceKindValue.known.map(\.rawValue) == ["device", "manual"])
        #expect(ServiceValue.primeVideo.isKnown)
        #expect(GenreValue.known.map(\.rawValue) == ["action", "adventure", "animation", "comedy", "crime", "documentary", "drama",
                                                      "family", "fantasy", "history", "horror", "music", "mystery", "romance",
                                                      "science_fiction", "tv_movie", "thriller", "war", "western", "kids", "news",
                                                      "reality", "soap", "talk", "politics"])
    }
}
