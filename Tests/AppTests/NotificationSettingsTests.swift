@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("NotificationSettings")
struct NotificationSettingsTests {
    func service(_ app: Application) -> NotificationSettingsService { NotificationSettingsService(db: app.db) }

    @Test func defaultsWithoutRow() async throws {
        try await withTestApp { app in
            let settings = try await service(app).settings()
            #expect(settings == NotificationSettings(dailyRunTime: "07:00", webhookURL: nil, lastRunAt: nil))
        }
    }

    @Test func savesTimeAndURL() async throws {
        try await withTestApp { app in
            let saved = try await service(app).save(dailyRunTime: "5:30", webhookURL: " https://knot.lan/hook ")
            #expect(saved.dailyRunTime == "05:30")
            #expect(saved.webhookURL == "https://knot.lan/hook")
            let stored = try await service(app).settings()
            #expect(stored == saved)
        }
    }

    @Test func rejectsQueryUserInfoAndScheme() async throws {
        try await withTestApp { app in
            for bad in ["https://knot.lan/hook?apiKey=x", "https://u:p@knot.lan/hook", "ftp://knot.lan", "https://knot.lan/hook#x",
                        "knot.lan", "https:///hook", "https://knot.lan/hook?"] {
                await #expect(throws: APIError.validation(NotificationSettingsService.webhookURLMessage), "\(bad)") {
                    try await service(app).save(dailyRunTime: "07:00", webhookURL: bad)
                }
            }
            let stored = try await service(app).settings()
            #expect(stored.webhookURL == nil)
        }
    }

    @Test func rejectsBadTime() async throws {
        try await withTestApp { app in
            await #expect(throws: APIError.validation(NotificationSettingsService.timeMessage)) {
                try await service(app).save(dailyRunTime: "25:00", webhookURL: nil)
            }
        }
    }

    @Test func emptyURLRemovesWebhook() async throws {
        try await withTestApp { app in
            try await service(app).save(dailyRunTime: "07:00", webhookURL: "http://knot:8080/hook")
            let cleared = try await service(app).save(dailyRunTime: "07:00", webhookURL: "  ")
            #expect(cleared.webhookURL == nil)
            try await service(app).save(dailyRunTime: "07:00", webhookURL: "http://knot:8080/hook")
            try await service(app).removeWebhook()
            let removed = try await service(app).settings()
            #expect(removed.webhookURL == nil)
        }
    }

    @Test func markRunStoresTime() async throws {
        try await withTestApp { app in
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            try await service(app).markRun(at: t)
            let stored = try await service(app).settings()
            #expect(stored.lastRunAt == t)
        }
    }

    @Test func saveWakesTrigger() async throws {
        try await withTestApp { app in
            try await app.notificationSettings.save(dailyRunTime: "06:00", webhookURL: nil)
            #expect(await app.dailyRunTrigger.sleep(until: Date().addingTimeInterval(5)))
        }
    }
}
