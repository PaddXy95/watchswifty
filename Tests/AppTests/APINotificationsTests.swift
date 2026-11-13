@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct NotificationPrefsBody: Codable, Equatable {
    let announced: Bool
    let soon: Bool
    let today: Bool
    let channel: String
    let activeChannel: String?
    let availableChannels: [String]
    let webhookConfigured: Bool
    let hasWebhookKey: Bool
    let dailyRunTime: String
}

struct NotificationPrefsUpdateBody: Content {
    var announced: Bool
    var soon: Bool
    var today: Bool
    var channel: String
}

struct WebhookKeyBody: Content {
    var key: String
    var currentPassword: String?
}

struct AdminNotificationsBody: Codable {
    let dailyRunTime: String
    let timeZone: String
    let webhookUrl: String?
    let lastRunAt: Date?
    let nextRunAt: Date
}

struct AdminNotificationsUpdateBody: Content {
    var dailyRunTime: String
    var webhookUrl: String?
}

@Suite("APINotifications")
struct APINotificationsTests {
    static let key = "k-1234567890abcdef-key"

    func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func prefsRoundTrip() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            let token = try await apiToken(app, pat)
            try await app.testing().test(.PUT, "/api/v1/me/notifications", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NotificationPrefsUpdateBody(announced: true, soon: false, today: true, channel: "mail"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "/api/v1/me/notifications", headers: .bearer(token)) { res async throws in
                let body = try JSONDecoder().decode(NotificationPrefsBody.self, from: Data(res.body.readableBytesView))
                #expect(body == NotificationPrefsBody(announced: true, soon: false, today: true, channel: "mail", activeChannel: "mail",
                                                      availableChannels: ["mail"], webhookConfigured: false, hasWebhookKey: false,
                                                      dailyRunTime: "07:00"))
            }
        }
    }

    @Test func unavailableChannelIsRejected() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let token = try await apiToken(app, try await notifyUser(app, "pat", email: "pat@x.de"))
            try await app.testing().test(.PUT, "/api/v1/me/notifications", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NotificationPrefsUpdateBody(announced: true, soon: false, today: true, channel: "webhook"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
            })
        }
    }

    @Test func keyNeverInResponse() async throws {
        try await withTestApp { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            let token = try await apiToken(app, pat)
            try await app.testing().test(.PUT, "/api/v1/me/notifications/webhook-key", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(WebhookKeyBody(key: Self.key, currentPassword: "password123"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains(Self.key))
                let body = try JSONDecoder().decode(NotificationPrefsBody.self, from: Data(res.body.readableBytesView))
                #expect(body.hasWebhookKey && body.availableChannels == ["webhook"])
            })
            try await app.testing().test(.DELETE, "/api/v1/me/notifications/webhook-key", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(["currentPassword": "password123"])
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(NotificationPrefsBody.self, from: Data(res.body.readableBytesView))
                #expect(!body.hasWebhookKey)
            })
        }
    }

    @Test func keyIgnoresPassword() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await notifyUser(app, "pat"))
            try await app.testing().test(.PUT, "/api/v1/me/notifications/webhook-key", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(WebhookKeyBody(key: Self.key, currentPassword: "falsch"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(NotificationPrefsBody.self, from: Data(res.body.readableBytesView))
                #expect(body.hasWebhookKey)
            })
            try await app.testing().test(.DELETE, "/api/v1/me/notifications/webhook-key", headers: .bearer(token), afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(NotificationPrefsBody.self, from: Data(res.body.readableBytesView))
                #expect(!body.hasWebhookKey)
            })
        }
    }

    @Test func testWithoutChannel() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await notifyUser(app, "pat"))
            try await app.testing().test(.POST, "/api/v1/me/notifications/test", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unprocessableEntity)
                let error = try JSONDecoder().decode(APIErrorBody.self, from: Data(res.body.readableBytesView))
                #expect(error.code == "notificationsNotConfigured")
                #expect(error.message == NotifyError.notConfigured.message)
            }
        }
    }

    @Test func testWebhookFailure() async throws {
        let webhook = FakeWebhookSender()
        webhook.failure = .status(502)
        try await withTestApp(webhook: webhook) { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key)
            let token = try await apiToken(app, pat)
            try await app.testing().test(.POST, "/api/v1/me/notifications/test", headers: .bearer(token)) { res async throws in
                #expect(res.status == .serviceUnavailable)
                let error = try JSONDecoder().decode(APIErrorBody.self, from: Data(res.body.readableBytesView))
                #expect(error.code == "notifyFailed")
                #expect(error.message == WebhookError.status(502).message)
            }
            webhook.failure = nil
            try await app.testing().test(.POST, "/api/v1/me/notifications/test", headers: .bearer(token)) { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(webhook.sent.map(\.message.subject) == ["WatchSwifty: Testnachricht"])
        }
    }

    @Test func adminSettings() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await createUser(app, "chef", isAdmin: true))
            try await app.testing().test(.PUT, "/api/v1/admin/notifications", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(AdminNotificationsUpdateBody(dailyRunTime: "06:15", webhookUrl: "https://knot.lan/hook"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "/api/v1/admin/notifications", headers: .bearer(token)) { res async throws in
                let body = try decoder().decode(AdminNotificationsBody.self, from: Data(res.body.readableBytesView))
                #expect(body.dailyRunTime == "06:15")
                #expect(body.webhookUrl == "https://knot.lan/hook")
                #expect(body.timeZone == TimeZone.current.identifier)
                #expect(body.lastRunAt == nil)
                #expect(body.nextRunAt > Date())
            }
            try await app.testing().test(.PUT, "/api/v1/admin/notifications", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(AdminNotificationsUpdateBody(dailyRunTime: "06:15", webhookUrl: "https://knot.lan/hook?apiKey=1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
            })
        }
    }

    @Test func adminOnly() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await createUser(app, "pat"))
            try await app.testing().test(.GET, "/api/v1/admin/notifications", headers: .bearer(token)) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
