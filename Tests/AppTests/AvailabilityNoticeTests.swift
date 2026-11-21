@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AvailabilityNotice")
struct AvailabilityNoticeTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Setup {
        let tmdb: FakeTMDBClient
        let user: User
        let title: Title
        let entry: WatchLaterEntry
    }

    /// User „pat“ (DE, services `services`), movie 603 „Dune“ on the list.
    func setup(_ app: Application, _ tmdb: FakeTMDBClient, services: [Int] = [8], baselined: Bool = true,
               notify: Bool = true) async throws -> Setup {
        let user = try await createUser(app, "pat")
        user.notifyAvailable = notify
        try await user.save(on: app.db)
        for id in services { try await UserStreamingService(userID: user.requireID(), providerID: id).save(on: app.db) }
        let title = try await seedMovie(app, tmdbID: 603, name: "Dune")
        let entry = WatchLaterEntry(userID: try user.requireID(), titleID: try title.requireID(), addedAt: start,
                                    addedOn: "2026-11-07", baselined: baselined)
        try await entry.save(on: app.db)
        return Setup(tmdb: tmdb, user: user, title: title, entry: entry)
    }

    /// Sets the offers in DE, fetches and reconciles.
    func offers(_ app: Application, _ s: Setup, _ offers: [TMDBOffer], region: String = "DE") async throws {
        s.tmdb.setWatchProviders(kind: .movie, id: 603, TMDBWatchProviders(offers: [region: offers]))
        try await AvailabilityService(db: app.db).refresh(s.title, tmdb: s.tmdb, now: start)
        try await AvailabilityNoticeService(db: app.db).reconcile(titleID: s.title.requireID(), now: start)
    }

    func states(_ app: Application) async throws -> [Int: NoticeState] {
        Dictionary(uniqueKeysWithValues: try await AvailabilityNotice.query(on: app.db).all().map { ($0.providerID, $0.noticeState!) })
    }

    @Test func alreadyAvailableWhenAddedIsBaseline() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb, baselined: false)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            #expect(try await states(app) == [8: .baseline])
            #expect(try await AvailabilityNoticeService(db: app.db).due(userID: s.user.requireID()).isEmpty)
            #expect(try await WatchLaterEntry.query(on: app.db).first()?.baselined == true)
        }
    }

    @Test func newOfferBecomesPending() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            #expect(try await states(app) == [8: .pending])
            let due = try await AvailabilityNoticeService(db: app.db).due(userID: s.user.requireID())
            #expect(due.count == 1)
            #expect(due.first?.providers == ["Netflix"])
            #expect(due.first?.name == "Dune")
            #expect(due.first?.tmdbID == 603)
        }
    }

    @Test func newOfferWithSwitchOffIsSkipped() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb, notify: false)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            #expect(try await states(app) == [8: .skipped])
            let service = AvailabilityNoticeService(db: app.db)
            #expect(try await service.due(userID: s.user.requireID()).isEmpty)
            #expect(try await service.newSince(userID: s.user.requireID(), since: start.addingTimeInterval(-60))[s.title.requireID()] == start)
        }
    }

    @Test func freeOfferAtOwnServiceNotifies() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb, services: [304])
            try await offers(app, s, [offer(304, "Joyn", .ads)])
            #expect(try await states(app) == [304: .pending])
        }
    }

    @Test func rentOrBuyNeverNotifies() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            try await offers(app, s, [offer(8, "Netflix", .buy), offer(8, "Netflix", .rent)])
            #expect(try await states(app).isEmpty)
        }
    }

    @Test func otherServiceDoesNotNotify() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            try await offers(app, s, [offer(337, "Disney Plus", .flatrate)])
            #expect(try await states(app).isEmpty)
        }
    }

    @Test func vanishedOfferDeletesNoticeAndReturnNotifiesAgain() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            let service = AvailabilityNoticeService(db: app.db)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            try await service.markSent(try await service.due(userID: s.user.requireID()))
            #expect(try await states(app) == [8: .sent])
            try await offers(app, s, [])
            #expect(try await states(app).isEmpty)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            #expect(try await states(app) == [8: .pending])
        }
    }

    @Test func uncoveredRegionKeepsNotices() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            // The availability now only covers DE; a user who moved to AT keeps the notice.
            s.user.watchRegion = "AT"
            try await s.user.save(on: app.db)
            try await AvailabilityNoticeService(db: app.db).reconcile(titleID: s.title.requireID(), now: start)
            #expect(try await states(app) == [8: .pending])
        }
    }

    @Test func rebaselineSwallowsExisting() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            let service = AvailabilityNoticeService(db: app.db)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            try await service.markSent(try await service.due(userID: s.user.requireID()))
            try await offers(app, s, [offer(8, "Netflix", .flatrate), offer(9, "Prime Video", .flatrate)])
            #expect(try await states(app) == [8: .sent])   // Prime is not a service of the user yet
            try await UserStreamingService(userID: s.user.requireID(), providerID: 9).save(on: app.db)
            try await service.rebaseline(userID: s.user.requireID())
            try await service.reconcile(titleID: s.title.requireID(), now: start)
            #expect(try await states(app) == [8: .sent, 9: .baseline])
            #expect(try await service.due(userID: s.user.requireID()).isEmpty)
        }
    }

    @Test func dueIgnoresRemovedEntries() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            try await s.entry.delete(on: app.db)
            #expect(try await AvailabilityNoticeService(db: app.db).due(userID: s.user.requireID()).isEmpty)
        }
    }

    @Test func otherUsersEntriesAreSeparate() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let s = try await setup(app, tmdb)
            let other = try await createUser(app, "sepp")
            try await offers(app, s, [offer(8, "Netflix", .flatrate)])
            #expect(try await AvailabilityNoticeService(db: app.db).due(userID: other.requireID()).isEmpty)
        }
    }
}
