@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct NotificationsForm: Content {
    var dailyRunTime: String
    var webhookURL: String
}

@Suite("SystemNotifications")
struct SystemNotificationsTests {
    func adminHeaders(_ app: Application) async throws -> HTTPHeaders {
        try await login(app, "admin", password: "adminpass123")
    }

    func post(_ app: Application, _ headers: HTTPHeaders, _ form: NotificationsForm,
              _ check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "/admin/system/notifications", headers: headers, beforeRequest: { req in
            try req.content.encode(form, as: .urlEncodedForm)
        }, afterResponse: check)
    }

    @Test func adminSavesTimeAndWebhook() async throws {
        try await withTestApp { app in
            try await post(app, try await adminHeaders(app), NotificationsForm(dailyRunTime: "05:30", webhookURL: "https://knot.lan/hook")) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Benachrichtigungen gespeichert."))
            }
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.dailyRunTime == "05:30")
            #expect(stored.webhookURL == "https://knot.lan/hook")
        }
    }

    @Test func invalidURLShowsMessage() async throws {
        try await withTestApp { app in
            try await post(app, try await adminHeaders(app), NotificationsForm(dailyRunTime: "06:15", webhookURL: "https://knot.lan/hook?apiKey=x")) { res in
                #expect(res.status == .unprocessableEntity)
                let body = res.body.string
                #expect(body.contains("Webhook-Adresse: z. B. https://knot.example.lan/hook"))
                #expect(body.contains("06:15"))
                #expect(body.contains("https://knot.lan/hook?apiKey=x"))
            }
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.webhookURL == nil)
        }
    }

    @Test func pageShowsKNotLinkAndTimeZone() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/admin/system", headers: try await adminHeaders(app)) { res async in
                let body = res.body.string
                #expect(body.contains("https://github.com/nexus421/KNot"))
                #expect(body.contains(DocsLink.baseURL + "notifications.md"))
                #expect(body.contains("Zeitzone des Servers: \(TimeZone.current.identifier)"))
                #expect(body.contains("Täglicher Abgleich um"))
                #expect(body.contains("Letzter Durchgang: noch keiner"))
            }
        }
    }

    @Test func nonAdminCannotSave() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            try await post(app, try await login(app, "pat"), NotificationsForm(dailyRunTime: "05:30", webhookURL: "https://knot.lan/hook")) { res in
                #expect(res.status == .forbidden)
            }
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.webhookURL == nil)
        }
    }

    @Test func removeWebhook() async throws {
        try await withTestApp { app in
            let headers = try await adminHeaders(app)
            try await configureWebhook(app)
            try await app.testing().test(.POST, "/admin/system/notifications/webhook/delete", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Webhook entfernt."))
            }
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.webhookURL == nil)
        }
    }
}
