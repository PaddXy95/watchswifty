@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("NotificationPass")
struct NotificationPassTests {
    typealias F = NoticeFixture

    func run(_ app: Application, now: Date = NoticeFixture.t2) async -> NotificationPassResult {
        await runNotifications(db: app.db, notifications: app.notifications, today: F.today, now: now, logger: app.logger)
    }

    /// pat (mail) follows two series with three due episodes.
    @discardableResult
    func seedPat(_ app: Application, email: String? = "pat@x.de") async throws -> User {
        let pat = try await notifyUser(app, "pat", email: email)
        let a = try await seedSeries(app, tmdbID: 1, name: "Andor", seasons: [1: 2], airDates: ["1x1": "2026-11-07", "1x2": "2026-11-09"])
        let b = try await seedSeries(app, tmdbID: 2, name: "Bosch", seasons: [1: 1], noAirDate: ["1x1"])
        try await F.follow(app, pat, a)
        try await F.follow(app, pat, b)
        try await F.seen(app, b, 1, 1)
        try await F.prefs(app, pat, announced: true, soon: true, today: true)
        return pat
    }

    @Test func oneDigestPerUser() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await seedPat(app)
            let result = await run(app)
            #expect(result.sent == 1 && result.failed == 0)
            #expect(mail.sent.count == 1)
            #expect(mail.sent.first?.header("Subject") == "WatchSwifty: 1 Folge heute, 1 Folge in den nächsten Tagen, 1 neu angekündigt")
            #expect(mail.sent.first?.body.contains("https://watch.example.lan/tv/1") == true)
        }
    }

    @Test func sentItemsAreNotRepeated() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await seedPat(app)
            _ = await run(app)
            let second = await run(app)
            #expect(second.sent == 0)
            #expect(mail.sent.count == 1)
        }
    }

    @Test func failedSendIsRetriedNextDay() async throws {
        let mail = FakeMailSender()
        mail.failure = MailError(message: "kaputt")
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await seedPat(app)
            let failed = await run(app)
            #expect(failed.failed == 1 && failed.sent == 0)
            #expect(try await EpisodeNotice.query(on: app.db).count() == 0)
            mail.failure = nil
            let retried = await run(app)
            #expect(retried.sent == 1)
            #expect(mail.sent.first?.header("Subject") == "WatchSwifty: 1 Folge heute, 1 Folge in den nächsten Tagen, 1 neu angekündigt")
        }
    }

    @Test func oneFailureDoesNotStopOthers() async throws {
        let mail = FakeMailSender()
        let webhook = FakeWebhookSender()
        webhook.failure = .status(502)
        try await withTestApp(mail: mail, webhook: webhook) { app in
            try await configureMail(app)
            try await configureWebhook(app)
            let pat = try await seedPat(app, email: nil)
            try await prefsService(app).setWebhookKey(user: pat, key: "k-1234567890abcdef")
            let bob = try await notifyUser(app, "bobby", email: "bob@x.de")
            let show = try await Title.query(on: app.db).filter(\.$tmdbID == 1).first()!
            try await F.follow(app, bob, show)
            try await F.prefs(app, bob, today: true)
            let result = await run(app)
            #expect(result.failed == 1 && result.sent == 1)
            #expect(mail.sent.map(\.to) == ["bob@x.de"])
        }
    }

    @Test func usersWithoutTogglesAreSkipped() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            let pat = try await seedPat(app)
            try await F.prefs(app, pat)
            let result = await run(app)
            #expect(result == NotificationPassResult())
            #expect(mail.sent.isEmpty)
        }
    }

    @Test func usersWithoutChannelAreSkipped() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await seedPat(app, email: nil)
            let bob = try await notifyUser(app, "bobby", email: "bob@x.de")
            let show = try await Title.query(on: app.db).filter(\.$tmdbID == 1).first()!
            try await F.follow(app, bob, show)
            try await F.prefs(app, bob, today: true)
            let result = await run(app)
            #expect(result.sent == 1 && result.failed == 0)
            #expect(try await EpisodeNotice.query(on: app.db).filter(\.$user.$id == (try await User.query(on: app.db).filter(\.$username == "pat").first()!.requireID())).count() == 0)
        }
    }

    @Test func cleanupRunsInPass() async throws {
        try await withTestApp { app in
            let pat = try await notifyUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-09-01"])
            let ep = try await episode(app, show, 1, 1)
            try await EpisodeNotice(userID: pat.requireID(), episodeID: ep.requireID(), kind: .today, airDate: "2026-09-01",
                                    sentAt: F.t0).save(on: app.db)
            let result = await run(app)
            #expect(result.cleaned == 1)
        }
    }

    @Test func dailyPassSendsAndRecordsItsStartTime() async throws {
        let mail = FakeMailSender()
        try await withTestApp(mail: mail) { app in
            try await configureMail(app)
            try await seedPat(app)
            await runDailyPass(app, now: F.t2)
            #expect(mail.sent.count == 1)
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.lastRunAt == F.t2)
        }
    }

    @Test func cancelledPassIsNotRecorded() async throws {
        try await withTestApp { app in
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                await runDailyPass(app, now: F.t2)
            }
            task.cancel()
            await task.value
            let stored = try await NotificationSettingsService(db: app.db).settings()
            #expect(stored.lastRunAt == nil)
        }
    }
}
