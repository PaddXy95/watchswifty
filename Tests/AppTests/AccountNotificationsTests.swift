@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct PrefsForm: Content {
    var announced: String?
    var soon: String?
    var today: String?
    var channel: String
}

struct KeyForm: Content {
    var key: String
    var currentPassword: String?
}

@Suite("AccountNotifications")
struct AccountNotificationsTests {
    static let key = "k-1234567890abcdef-key"

    func page(_ app: Application, _ headers: HTTPHeaders) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, "/account", headers: headers) { res async in body = res.body.string }
        return body
    }

    func reload(_ app: Application, _ user: User) async throws -> User {
        try #require(try await User.find(user.requireID(), on: app.db))
    }

    @Test func savesToggles() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/notifications", headers: headers, beforeRequest: { req in
                try req.content.encode(PrefsForm(announced: "on", soon: nil, today: "on", channel: "mail"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Benachrichtigungen gespeichert."))
            })
            let stored = try await reload(app, pat)
            #expect(stored.notifyAnnounced == true && stored.notifySoon == false && stored.notifyToday == true)
            #expect(stored.preferredChannel == .mail)
        }
    }

    @Test func channelChoiceOnlyWhenBothAvailable() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            let headers = try await login(app, "pat")
            let mailOnly = try await page(app, headers)
            #expect(mailOnly.contains("Benachrichtigungen"))
            #expect(!mailOnly.contains(#"value="webhook""#))
            #expect(mailOnly.contains("Senden per E-Mail"))
            try await configureWebhook(app)
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            let both = try await page(app, headers)
            #expect(both.contains(#"value="webhook""#))
            #expect(both.contains(#"value="mail""#))
        }
    }

    @Test func noChannelHint() async throws {
        try await withTestApp { app in
            try await notifyUser(app, "pat")
            let body = try await page(app, try await login(app, "pat"))
            #expect(body.contains("Noch kein Versandweg"))
        }
    }

    @Test func keyIsNeverShownAgain() async throws {
        try await withTestApp { app in
            try await configureWebhook(app)
            try await notifyUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/notifications/webhook-key", headers: headers, beforeRequest: { req in
                try req.content.encode(KeyForm(key: Self.key, currentPassword: "password123"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Webhook-Schlüssel gespeichert."))
                #expect(!res.body.string.contains(Self.key))
            })
            let body = try await page(app, headers)
            #expect(!body.contains(Self.key))
            #expect(body.contains("Schlüssel entfernen"))
        }
    }

    @Test func keyWithWrongPasswordFails() async throws {
        try await withTestApp { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await app.testing().test(.POST, "/account/notifications/webhook-key", headers: try await login(app, "pat"), beforeRequest: { req in
                try req.content.encode(KeyForm(key: Self.key, currentPassword: "falsch"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(AccountValidation.wrongCurrentPasswordMessage))
            })
            #expect(try await reload(app, pat).webhookKey == nil)
        }
    }

    @Test func removeKey() async throws {
        try await withTestApp { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            try await app.testing().test(.POST, "/account/notifications/webhook-key/remove", headers: try await login(app, "pat"),
                                         beforeRequest: { req in
                try req.content.encode(["currentPassword": "password123"], as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Webhook-Schlüssel entfernt."))
            })
            #expect(try await reload(app, pat).webhookKey == nil)
        }
    }

    @Test func testNotificationGoesOut() async throws {
        let webhook = FakeWebhookSender()
        try await withTestApp(webhook: webhook) { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            try await app.testing().test(.POST, "/account/notifications/test", headers: try await login(app, "pat")) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Testnachricht gesendet."))
            }
            #expect(webhook.sent.map(\.message.subject) == ["WatchSwifty: Testnachricht"])
        }
    }

    @Test func testFailureShowsMessage() async throws {
        let webhook = FakeWebhookSender()
        webhook.failure = .status(502)
        try await withTestApp(webhook: webhook) { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            try await app.testing().test(.POST, "/account/notifications/test", headers: try await login(app, "pat")) { res async in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains(WebhookError.status(502).message))
            }
        }
    }

    @Test func keyBlockHiddenWithoutWebhook() async throws {
        try await withTestApp { app in
            try await notifyUser(app, "pat")
            let body = try await page(app, try await login(app, "pat"))
            #expect(!body.contains("Webhook-Schlüssel (KNot)"))
        }
    }

    @Test func keyBlockShownWithWebhook() async throws {
        try await withTestApp { app in
            try await configureWebhook(app)
            try await notifyUser(app, "pat")
            let body = try await page(app, try await login(app, "pat"))
            #expect(body.contains("Webhook-Schlüssel (KNot)"))
            #expect(body.contains(#"action="/account/notifications/webhook-key""#))
        }
    }
}
