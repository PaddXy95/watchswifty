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

    @Test func knownValuesMatchSpec() {
        #expect(ServiceValue.known.map(\.rawValue) == ["netflix", "prime_video", "disney_plus", "apple_tv", "hbo_max",
                                                        "paramount_plus", "wow", "cinema", "purchased", "other"])
        #expect(WatchOriginValue.known.map(\.rawValue) == ["manual", "import"])
        #expect(MappingStatusValue.known.map(\.rawValue) == ["pending", "auto", "confirmed", "review", "ignored"])
        #expect(FilmStatusValue.known.map(\.rawValue) == ["pending", "imported", "review", "not_found", "skipped"])
        #expect(DeviceKindValue.known.map(\.rawValue) == ["device", "manual"])
        #expect(ServiceValue.primeVideo.isKnown)
    }
}
