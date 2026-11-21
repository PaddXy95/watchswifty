@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("StreamingSettings")
struct StreamingSettingsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func saveReplacesServicesAndRegion() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let service = StreamingSettingsService(db: app.db)
            #expect(try await service.settings(user: user) == StreamingSettings(region: "DE", providerIDs: []))
            #expect(try await !service.save(user: user, region: "DE", providerIDs: [8, 337]))
            #expect(try await service.save(user: user, region: "AT", providerIDs: [8, 8]))
            #expect(try await service.settings(user: user) == StreamingSettings(region: "AT", providerIDs: [8]))
            #expect(try await User.find(user.requireID(), on: app.db)?.watchRegion == "AT")
        }
    }

    @Test(arguments: ["de", "DEU", "", "D1"]) func saveRejectsInvalidRegion(_ region: String) async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            await #expect(throws: APIError.validation(StreamingSettingsService.regionMessage)) {
                _ = try await StreamingSettingsService(db: app.db).save(user: user, region: region, providerIDs: [])
            }
        }
    }

    @Test func saveRejectsInvalidIDs() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            await #expect(throws: APIError.validation(StreamingSettingsService.providersMessage)) {
                _ = try await StreamingSettingsService(db: app.db).save(user: user, region: "DE", providerIDs: [0])
            }
            await #expect(throws: APIError.validation(StreamingSettingsService.providersMessage)) {
                _ = try await StreamingSettingsService(db: app.db).save(user: user, region: "DE", providerIDs: Array(1...201))
            }
        }
    }

    @Test func changeRebaselines() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await WatchLaterEntry(userID: user.requireID(), titleID: movie.requireID(), addedAt: start, addedOn: "2026-11-07",
                                      baselined: true).save(on: app.db)
            let service = StreamingSettingsService(db: app.db)
            _ = try await service.save(user: user, region: "DE", providerIDs: [])
            #expect(try await WatchLaterEntry.query(on: app.db).first()?.baselined == true)   // nothing changed
            _ = try await service.save(user: user, region: "DE", providerIDs: [8])
            #expect(try await WatchLaterEntry.query(on: app.db).first()?.baselined == false)
        }
    }

    @Test func fetchMissingOnlyUncoveredTitles() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            user.watchRegion = "AT"
            try await user.save(on: app.db)
            let covered = try await seedMovie(app, tmdbID: 603)
            let missing = try await seedMovie(app, tmdbID: 604)
            for title in [covered, missing] {
                try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(), addedAt: start, addedOn: "2026-11-07",
                                          baselined: true).save(on: app.db)
            }
            try await AvailabilityService(db: app.db).refresh(covered, tmdb: tmdb, now: start)
            let before = tmdb.calls.count
            await StreamingSettingsService(db: app.db).fetchMissing(userID: try user.requireID(), region: "AT", tmdb: tmdb, logger: app.logger)
            #expect(Array(tmdb.calls.dropFirst(before)) == ["watch_providers:movie:604"])
        }
    }
}
