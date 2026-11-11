@testable import App
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

struct ForgotForm: Content { var username: String }

@Suite("ForgotPassword")
struct ForgotPasswordTests {
    static let answer = "Falls es das Konto gibt und eine Mail-Adresse hinterlegt ist, ist eine Mail unterwegs. Der Link gilt eine Stunde."
    static let mailOff = "Der Mail-Versand ist nicht eingerichtet. Bitte wende dich an deinen Admin."

    @discardableResult
    func userWithEmail(_ app: Application, _ name: String, email: String, password: Bool = true) async throws -> User {
        let user = User(username: name, passwordHash: password ? try app.password.hash("password123") : User.noPasswordHash, isAdmin: false)
        user.email = try app.tokenCipher.seal(email)
        try await user.save(on: app.db)
        return user
    }

    /// Posts the form, waits for the background mail and returns status and body.
    func forgot(_ app: Application, _ username: String) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.testing().test(.POST, "/forgot-password", headers: .sameOrigin, beforeRequest: { req in
            try req.content.encode(ForgotForm(username: username), as: .urlEncodedForm)
        }, afterResponse: { res async in
            result = (res.status, res.body.string)
        })
        await app.backgroundTasks.drain()
        return result
    }

    func service(_ app: Application) -> ForgotPasswordService {
        ForgotPasswordService(db: app.db, cipher: app.tokenCipher, mail: app.mail, logger: app.logger)
    }

    @Test func sameAnswerForEveryone() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            try await userWithEmail(app, "pat", email: "pat@x.de")
            try await userWithEmail(app, "neu", email: "neu@x.de", password: false)
            try await createUser(app, "ohne")
            var bodies: Set<String> = []
            for name in ["pat", "neu", "ohne", "nobody"] {
                let (status, body) = try await forgot(app, name)
                #expect(status == .ok, "\(name)")
                #expect(body.contains(Self.answer))
                bodies.insert(body)
            }
            #expect(bodies.count == 1)
        }
    }

    @Test func sendsResetMail() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await userWithEmail(app, "pat", email: "pat@x.de")
            _ = try await forgot(app, " PAT ")
            let sent = try #require(fake.sent.first)
            #expect(fake.sent.count == 1)
            #expect(sent.to == "pat@x.de")
            #expect(sent.header("Subject") == "WatchSwifty: Passwort zurücksetzen")
            #expect(sent.body.contains("pat"))
            let token = try #require(sent.body.firstMatch(of: #/https://watch\.example\.lan/reset-password\?token=([A-Za-z0-9_-]+)/#)?.output.1)
            try await app.testing().test(.GET, "/reset-password?token=\(token)") { res async in
                #expect(res.body.string.contains("name=\"passwordRepeat\""))
            }
        }
    }

    @Test func throttled() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await userWithEmail(app, "pat", email: "pat@x.de")
            _ = try await forgot(app, "pat")
            _ = try await forgot(app, "pat")
            #expect(fake.sent.count == 1)
            await service(app).handle(username: "pat", now: Date().addingTimeInterval(301))
            #expect(fake.sent.count == 2)
        }
    }

    @Test func noMailForNoPasswordOrUnreadable() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await userWithEmail(app, "neu", email: "neu@x.de", password: false)
            let pat = try await createUser(app, "pat")
            pat.email = try TokenCipher(key: SymmetricKey(size: .bits256)).seal("pat@x.de")
            try await pat.save(on: app.db)
            _ = try await forgot(app, "neu")
            _ = try await forgot(app, "pat")
            #expect(fake.sent.isEmpty)
            #expect(try await PasswordToken.query(on: app.db).count() == 0)
        }
    }

    /// The answer comes while the (slow) send is still running. Checked by the send's result, not by wall-clock time:
    /// on a loaded CI runner the request alone can take longer than a fixed bound.
    @Test func answerDoesNotWait() async throws {
        let fake = FakeMailSender()
        fake.delay = .seconds(5)
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await userWithEmail(app, "pat", email: "pat@x.de")
            try await app.testing().test(.POST, "/forgot-password", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(ForgotForm(username: "pat"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains(Self.answer))
                #expect(fake.sent.isEmpty, "the response waited for the mail")
            })
            await app.backgroundTasks.drain()
            #expect(fake.sent.count == 1)
        }
    }

    @Test func sendFailureOnlyLogged() async throws {
        let fake = FakeMailSender()
        fake.failure = MailError(message: "Mailserver nicht erreichbar (refused).")
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await userWithEmail(app, "pat", email: "pat@x.de")
            let (status, body) = try await forgot(app, "pat")
            #expect(status == .ok)
            #expect(body.contains(Self.answer))
        }
    }

    @Test func loginLinkOnlyWhenConfigured() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/login") { res async in
                #expect(!res.body.string.contains("Passwort vergessen?"))
            }
            try await app.testing().test(.GET, "/forgot-password") { res async in
                #expect(res.body.string.contains(Self.mailOff))
                #expect(!res.body.string.contains("name=\"username\""))
            }
            let (_, body) = try await forgot(app, "admin")
            #expect(body.contains(Self.mailOff))
            try await configureMail(app)
            try await app.testing().test(.GET, "/login") { res async in
                #expect(res.body.string.contains("href=\"/forgot-password\""))
                #expect(res.body.string.contains("Passwort vergessen?"))
            }
            try await app.testing().test(.GET, "/forgot-password") { res async in
                #expect(res.body.string.contains("name=\"username\""))
            }
        }
    }
}
