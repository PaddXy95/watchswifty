@testable import App
import Foundation
import NIOConcurrencyHelpers
import SwiftySMTPClient
import Testing
import VaporTesting

@Suite("MailSender")
struct MailSenderTests {
    @Test func describesSMTPErrorsMasked() {
        #expect(MailError.smtp(.rejected(stage: .auth, reply: SMTPReply(535, "auth failed"))).message
            == "Anmeldung am Mailserver abgelehnt (535) – Benutzer und Passwort prüfen.")
        #expect(MailError.smtp(.tlsFailed("certificate verify failed")).message.contains("Zertifikat"))
        #expect(MailError.smtp(.startTLSNotOffered).message.contains("STARTTLS"))
        #expect(MailError.smtp(.connectFailed("connection refused")).message.contains("nicht erreichbar"))
        let rejected = MailError.smtp(.rejected(stage: .rcptTo, reply: SMTPReply(550, "<alice@example.org> unknown"))).message
        #expect(rejected.contains("a•••@example.org"))
        #expect(!rejected.contains("alice@"))
    }

    @Test func caFileUnreadable() async throws {
        let settings = MailSettings(host: "relay.test", port: 2525, encryption: .starttls, username: nil, password: nil,
                                    fromAddress: "noreply@example.org", fromName: "WatchSwifty", caFile: "/nonexistent.pem",
                                    baseURL: "https://watch.example.lan")
        await #expect(throws: MailError.caFileUnreadable("/nonexistent.pem")) {
            try await LiveMailSender().send(Data("x".utf8), from: "noreply@example.org", to: "p@x.de", settings: settings)
        }
        #expect(MailError.caFileUnreadable("/nonexistent.pem").message == "CA-Datei /nonexistent.pem nicht lesbar.")
    }

    @Test func notConfiguredThrows() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            await #expect(throws: MailError.notConfigured) {
                try await app.mail.send(OutgoingMail(to: "p@x.de", subject: "s", body: "b"))
            }
            #expect(fake.sent.isEmpty)
            #expect(MailError.notConfigured.message == "Der Mail-Versand ist nicht eingerichtet.")
        }
    }

    @Test func sendUsesStoredSettings() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await app.mail.sendTest(to: " p@X.de ")
            let sent = try #require(fake.sent.first)
            #expect(fake.sent.count == 1)
            #expect(sent.from == "noreply@example.org")
            #expect(sent.to == "p@x.de")
            #expect(sent.header("Subject") == "WatchSwifty: Testmail")
            #expect(sent.header("Message-ID")?.hasSuffix("@example.org>") == true)
            #expect(sent.header("From") == "WatchSwifty <noreply@example.org>")
            await #expect(throws: APIError.validation(EmailAddress.invalidMessage)) {
                try await app.mail.sendTest(to: "nope")
            }
        }
    }

    @Test func sendHonorsDeadline() async throws {
        var config = AppConfig.testing
        config.mailDeadline = .milliseconds(200)
        let fake = FakeMailSender()
        fake.delay = .seconds(5)
        try await withTestApp(config: config, mail: fake) { app in
            try await configureMail(app)
            let started = ContinuousClock.now
            await #expect(throws: MailError.timeout) {
                try await app.mail.sendTest(to: "p@x.de")
            }
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(MailError.timeout.message == "Der Mailserver hat nicht rechtzeitig geantwortet.")
        }
    }

    @Test func mailTexts() {
        let reset = MailTexts.reset(to: "p@x.de", username: "pat", link: "https://w/reset-password?token=t")
        #expect(reset.subject == "WatchSwifty: Passwort zurücksetzen")
        #expect(reset.body.contains("pat") && reset.body.contains("https://w/reset-password?token=t"))
        let expires = try! #require(ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z"))
        let invite = MailTexts.invite(to: "n@x.de", username: "neu", inviter: "admin", link: "https://w/l", expires: expires)
        #expect(invite.subject == "Einladung zu WatchSwifty")
        for part in ["neu", "admin", "https://w/l", "16.11.2026", "TMDB"] { #expect(invite.body.contains(part), "\(part)") }
        #expect(MailTexts.test(to: "p@x.de").subject == "WatchSwifty: Testmail")
    }

    @Test func backgroundTasksDrain() async {
        let tasks = BackgroundTasks()
        let done = NIOLockedValueBox(0)
        for _ in 0..<3 {
            tasks.run {
                try? await Task.sleep(for: .milliseconds(50))
                done.withLockedValue { $0 += 1 }
            }
        }
        await tasks.drain()
        #expect(done.withLockedValue { $0 } == 3)
    }
}
