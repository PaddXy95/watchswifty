@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AvailabilityModel")
struct AvailabilityModelTests {
    @Test func duplicateWatchLaterRejected() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 603)
            try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            await #expect(throws: (any Error).self) {
                try await WatchLaterEntry(userID: user.requireID(), titleID: title.requireID(), addedAt: .now, addedOn: "2026-11-07")
                    .save(on: app.db)
            }
        }
    }

    @Test func userRegionDefaultsToDE() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            #expect(user.region == "DE")
            user.watchRegion = "AT"
            try await user.save(on: app.db)
            #expect(try await User.find(user.requireID(), on: app.db)?.region == "AT")
        }
    }

    @Test func availabilityRegionList() {
        let availability = TitleAvailability(titleID: UUID(), fetchedAt: .now, regions: ["DE", "AT"], tmdbLink: nil)
        #expect(availability.regions == "AT,DE")
        #expect(availability.regionList == ["AT", "DE"])
    }
}
