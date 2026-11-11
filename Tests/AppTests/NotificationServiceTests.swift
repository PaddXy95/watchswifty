@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Creates a user with an optional (sealed) address and password.
@discardableResult
func notifyUser(_ app: Application, _ name: String, email: String? = nil, password: String? = "password123") async throws -> User {
    let hash = try password.map { try app.password.hash($0) } ?? User.noPasswordHash
    let user = User(username: name, passwordHash: hash, isAdmin: false)
    user.email = try email.map { try app.tokenCipher.seal($0) }
    try await user.save(on: app.db)
    return user
}

func configureWebhook(_ app: Application, url: String = "https://knot.example.lan/hook") async throws {
    try await NotificationSettingsService(db: app.db).save(dailyRunTime: "07:00", webhookURL: url)
}

func prefsService(_ app: Application) -> NotificationPrefsService {
    NotificationPrefsService(db: app.db, hasher: app.password.async, cipher: app.tokenCipher)
}

@Suite("NotificationService")
struct NotificationServiceTests {
    static let key = "k-1234567890abcdef-key"
    let message = NotificationMessage(subject: "WatchSwifty: Betreff", body: "Text")

    @Test func noChannelWithoutSetup() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            let available = try await app.notifications.availableChannels(for: pat)
            let active = try await app.notifications.activeChannel(for: pat)
            #expect(available.isEmpty)
            #expect(active == nil)
            await #expect(throws: NotifyError.notConfigured) { try await app.notifications.send(message, to: pat) }
        }
    }

    @Test func mailWhenAddressAndMailConfigured() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            let channel = try await app.notifications.send(message, to: pat)
            #expect(channel == .mail)
            #expect(mail.sent.count == 1)
            #expect(mail.sent.first?.to == "pat@x.de")
            #expect(mail.sent.first?.header("Subject") == "WatchSwifty: Betreff")
        }
    }

    @Test func webhookWhenChosenAndKeySet() async throws {
        let mail = FakeMailSender()
        let webhook = FakeWebhookSender()
        try await withTestApp(mail: mail, webhook: webhook) { app in
            try await configureMail(app)
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            let available = try await app.notifications.availableChannels(for: pat)
            #expect(available == [.mail, .webhook])
            try await prefsService(app).save(user: pat, announced: false, soon: false, today: false, channel: .webhook, available: available)
            let channel = try await app.notifications.send(message, to: pat)
            #expect(channel == .webhook)
            #expect(webhook.sent.first?.key == Self.key)
            #expect(webhook.sent.first?.url == "https://knot.example.lan/hook")
            #expect(webhook.sent.first?.message == message)
            #expect(mail.sent.isEmpty)
        }
    }

    @Test func fallsBackWhenPreferredMissing() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            try await prefsService(app).save(user: pat, announced: false, soon: false, today: false, channel: .webhook,
                                             available: [.mail, .webhook])
            try await NotificationSettingsService(db: app.db).removeWebhook()
            let channel = try await app.notifications.send(message, to: pat)
            #expect(channel == .mail)
            #expect(mail.sent.count == 1)
        }
    }

    @Test func webhookErrorIsWrapped() async throws {
        let webhook = FakeWebhookSender()
        webhook.failure = .status(401)
        try await withTestApp(webhook: webhook) { app in
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            await #expect(throws: NotifyError(message: WebhookError.status(401).message)) {
                try await app.notifications.send(message, to: pat)
            }
        }
    }

    @Test func keyNeedsCurrentPassword() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat")
            await #expect(throws: APIError.validation(AccountValidation.wrongCurrentPasswordMessage)) {
                try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "falsch")
            }
            #expect(pat.webhookKey == nil)
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            let stored = try #require(try await User.find(pat.requireID(), on: app.db))
            #expect(stored.webhookKey != nil && stored.webhookKey != Self.key)
            #expect(stored.webhookKeyState(app.tokenCipher) == .key(Self.key))
            try await prefsService(app).setWebhookKey(user: stored, key: "  ", currentPassword: "password123")
            #expect(stored.webhookKeyState(app.tokenCipher) == WebhookKeyState.none)
        }
    }

    @Test func keyWithoutPasswordForSSOOnlyAccount() async throws {
        try await withTestApp { app in
            let sso = try await notifyUser(app, "sso", password: nil)
            try await prefsService(app).setWebhookKey(user: sso, key: Self.key, currentPassword: nil)
            #expect(sso.webhookKeyState(app.tokenCipher) == .key(Self.key))
        }
    }

    @Test func rejectsShortOrSpacedKey() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat")
            for bad in ["kurz", "mit leerzeichen drin 123", "umlaut-ä-1234567890"] {
                await #expect(throws: APIError.validation(NotificationPrefsService.keyMessage), "\(bad)") {
                    try await prefsService(app).setWebhookKey(user: pat, key: bad, currentPassword: "password123")
                }
            }
        }
    }

    @Test func savingUnavailableChannelFails() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat")
            await #expect(throws: APIError.validation(NotificationPrefsService.channelMessage)) {
                try await prefsService(app).save(user: pat, announced: true, soon: false, today: false, channel: .webhook, available: [.mail])
            }
        }
    }

    @Test func enablingAnnouncedStampsSince() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat")
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            try await prefsService(app).save(user: pat, announced: true, soon: true, today: false, channel: .mail, available: [], now: t)
            #expect(pat.notifyAnnouncedSince == t)
            #expect(pat.notifyAnnounced == true && pat.notifySoon == true && pat.notifyToday == false)
            try await prefsService(app).save(user: pat, announced: true, soon: false, today: true, channel: .mail, available: [],
                                             now: t.addingTimeInterval(60))
            #expect(pat.notifyAnnouncedSince == t)
        }
    }

    @Test func deviceNoticeGoesByWebhook() async throws {
        let mail = FakeMailSender()
        let webhook = FakeWebhookSender()
        try await withTestApp(mail: mail, webhook: webhook) { app in
            try await configureMail(app)
            try await configureWebhook(app)
            let pat = try await notifyUser(app, "pat", email: "pat@x.de")
            try await prefsService(app).setWebhookKey(user: pat, key: Self.key, currentPassword: "password123")
            try await prefsService(app).save(user: pat, announced: false, soon: false, today: false, channel: .webhook,
                                             available: [.mail, .webhook])
            await app.deviceNotice.handle(userID: try pat.requireID(), deviceName: "iPhone")
            #expect(webhook.sent.map(\.message.subject) == ["WatchSwifty: Neues Gerät verbunden"])
            #expect(webhook.sent.first?.message.body.contains("https://watch.example.lan/account") == true)
            #expect(mail.sent.isEmpty)
        }
    }

    @Test func newDeviceWithoutLink() {
        let text = NotificationTexts.newDevice(username: "pat", device: "iPhone", at: Date(), link: nil)
        #expect(!text.body.contains("http"))
        #expect(text.body.contains("Konto → Geräte"))
    }
}
