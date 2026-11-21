@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

func offer(_ id: Int, _ name: String, _ kind: OfferKind, priority: Int = 1) -> TMDBOffer {
    TMDBOffer(providerID: id, name: name, logoPath: "/\(id).jpg", displayPriority: priority, kind: kind)
}

@Suite("AvailabilityService")
struct AvailabilityServiceTests {
    static let day: TimeInterval = 86_400
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func refreshStoresOnlyRegionsInUse() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(
            links: ["DE": "https://tmdb/de"],
            offers: ["DE": [offer(8, "Netflix", .flatrate)], "AT": [offer(337, "Disney Plus", .flatrate)],
                     "US": [offer(15, "Hulu", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let austrian = try await createUser(app, "sepp")
            austrian.watchRegion = "AT"
            try await austrian.save(on: app.db)
            let title = try await seedMovie(app, tmdbID: 603)
            try await AvailabilityService(db: app.db).refresh(title, tmdb: tmdb, now: start)

            let rows = try await TitleProvider.query(on: app.db).all()
            #expect(Set(rows.map(\.region)) == ["AT", "DE"])
            let availability = try #require(try await TitleAvailability.query(on: app.db).first())
            #expect(availability.regions == "AT,DE")
            #expect(availability.tmdbLink == "https://tmdb/de")
            #expect(tmdb.calls == ["watch_providers:movie:603"])
        }
    }

    @Test func refreshFailureKeepsOldState() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            let service = AvailabilityService(db: app.db)
            try await service.refresh(title, tmdb: tmdb, now: start)
            tmdb.fail("watch_providers:movie:603", with: .rateLimited)
            await #expect(throws: TMDBError.rateLimited) {
                try await service.refresh(title, tmdb: tmdb, now: start.addingTimeInterval(Self.day))
            }
            #expect(try await TitleProvider.query(on: app.db).count() == 1)
            #expect(try await TitleAvailability.query(on: app.db).first()?.fetchedAt == start)
        }
    }

    @Test func snapshotNilWhenRegionNotCovered() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            let service = AvailabilityService(db: app.db)
            try await service.refresh(title, tmdb: tmdb, now: start)
            let titleID = try title.requireID()
            #expect(try await service.snapshot(titleID: titleID, region: "DE")?.offers.map(\.name) == ["Netflix"])
            #expect(try await service.snapshot(titleID: titleID, region: "AT") == nil)
            #expect(try await service.needsRefresh(titleID: titleID, region: "AT", now: start))
            #expect(try await !service.needsRefresh(titleID: titleID, region: "DE", now: start))
        }
    }

    @Test func emptyCoveredRegionIsAnEmptySnapshot() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            let service = AvailabilityService(db: app.db)
            try await service.refresh(title, tmdb: tmdb, now: start)
            #expect(try await service.snapshot(titleID: title.requireID(), region: "DE") == AvailabilitySnapshot(fetchedAt: start, offers: []))
        }
    }

    @Test func needsRefreshAfterSevenDays() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            let service = AvailabilityService(db: app.db)
            try await service.refresh(title, tmdb: tmdb, now: start)
            let titleID = try title.requireID()
            #expect(try await service.needsRefresh(titleID: titleID, region: "DE", now: start.addingTimeInterval(8 * Self.day)))
            #expect(try await !service.needsRefresh(titleID: titleID, region: "DE", now: start.addingTimeInterval(6 * Self.day)))
        }
    }

    @Test func expireDeletesAfterThirtyDays() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            let fresh = try await seedMovie(app, tmdbID: 604)
            let service = AvailabilityService(db: app.db)
            try await service.refresh(title, tmdb: tmdb, now: start)
            try await service.refresh(fresh, tmdb: tmdb, now: start.addingTimeInterval(20 * Self.day))
            try await AvailabilityNotice(userID: user.requireID(), titleID: title.requireID(), providerID: 8, noticedAt: start,
                                         state: .sent).save(on: app.db)

            #expect(try await service.expire(now: start.addingTimeInterval(31 * Self.day)) == 1)
            #expect(try await TitleAvailability.query(on: app.db).count() == 1)
            #expect(try await TitleProvider.query(on: app.db).filter(\.$title.$id == title.requireID()).count() == 0)
            #expect(try await AvailabilityNotice.query(on: app.db).count() == 1)
        }
    }

    @Test func groupsSplitOwnAndOtherSubscriptions() {
        let offers = [Offer(offer(8, "Netflix", .flatrate, priority: 1)), Offer(offer(337, "Disney Plus", .flatrate, priority: 2)),
                      Offer(offer(304, "Joyn", .ads, priority: 3)), Offer(offer(2, "Apple TV", .rent, priority: 4)),
                      Offer(offer(2, "Apple TV", .buy, priority: 4))]
        let snapshot = AvailabilitySnapshot(fetchedAt: start, offers: offers)
        let groups = AvailabilityGroups(snapshot: snapshot, services: [8])
        #expect(groups.hasServices)
        #expect(groups.mine.map(\.name) == ["Netflix"])
        #expect(groups.otherSubscriptions.map(\.name) == ["Disney Plus"])
        #expect(groups.free.map(\.name) == ["Joyn"])
        #expect(groups.rentOrBuy.count == 2)
        #expect(!AvailabilityGroups(snapshot: snapshot, services: []).hasServices)
        #expect(AvailabilityGroups(snapshot: snapshot, services: []).otherSubscriptions.count == 2)
    }

    @Test func providerLinkMapping() {
        #expect(StreamingService(tmdbProviderID: 8) == .netflix)
        #expect(StreamingService(tmdbProviderID: 337) == .disneyPlus)
        #expect(StreamingService(tmdbProviderID: 4242) == nil)
    }
}
