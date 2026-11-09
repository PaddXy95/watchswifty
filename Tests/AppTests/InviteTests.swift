@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct InviteForm: Content { var username: String; var email: String; var password = ""; var isAdmin = false }
struct InviteBody: Content { var username: String; var email: String?; var password: String? = nil; var isAdmin = false }
struct InviteSummaryBody: Codable {
    let id: UUID
    let username: String
    let invitePending: Bool
    let emailHint: String?
    let inviteExpiresAt: Date?
    let inviteMailError: String?
}

@Suite("Invite")
struct InviteTests {
    static let mailOffError = "Einladungen gehen erst, wenn der Mail-Versand unter System eingerichtet ist."
    static let mailOffHint = "Einladungen per Mail gehen erst, wenn der Mail-Versand unter System eingerichtet ist."
    static let failure = MailError(message: "Mailserver nicht erreichbar (refused).")

    func admin(_ app: Application) async throws -> HTTPHeaders {
        try await login(app, "admin", password: "adminpass123")
    }

    func invite(_ app: Application, _ headers: HTTPHeaders, _ form: InviteForm,
                _ check: @escaping @Sendable (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "/admin/users", headers: headers, beforeRequest: { req in
            try req.content.encode(form, as: .urlEncodedForm)
        }, afterResponse: check)
    }

    func user(_ app: Application, _ name: String) async throws -> User? {
        try await User.query(on: app.db).filter(\.$username == name).first()
    }

    func token(in mail: FakeMailSender.Sent) -> String? {
        mail.body.firstMatch(of: #/reset-password\?token=([A-Za-z0-9_-]+)/#).map { String($0.output.1) }
    }

    @Test func inviteCreatesAccountWithoutPassword() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "Neu", email: "neu@x.de")) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Einladung an n•••@x.de gesendet."))
            }
            let neu = try #require(try await user(app, "neu"))
            #expect(!neu.hasPassword)
            #expect(neu.emailState(app.tokenCipher) == .address("neu@x.de"))
            let sent = try #require(fake.sent.first)
            #expect(sent.to == "neu@x.de")
            #expect(sent.header("Subject") == "Einladung zu WatchSwifty")
            let expiry = CalendarDay.display(CalendarDay.today(now: Date().addingTimeInterval(7 * 86_400)))
            for part in ["neu", "admin", "https://watch.example.lan/reset-password?token=", expiry, "TMDB"] {
                #expect(sent.body.contains(part), "\(part)")
            }
            try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(LoginForm(username: "neu", password: "!"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(AuthController.failureMessage))
            })
        }
    }

    @Test func inviteNeedsMail() async throws {
        try await withTestApp { app in
            let headers = try await admin(app)
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.body.string.contains(Self.mailOffHint))
            }
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(Self.mailOffError))
            }
            #expect(try await user(app, "neu") == nil)
        }
    }

    @Test func inviteMailFailureKeepsAccount() async throws {
        let fake = FakeMailSender()
        fake.failure = Self.failure
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { res in
                #expect(res.status == .badGateway)
                #expect(res.body.string.contains("Konto angelegt, aber die Einladung konnte nicht gesendet werden: Mailserver nicht erreichbar (refused)."))
                #expect(res.body.string.contains("Einladung erneut senden"))
            }
            #expect(try await user(app, "neu") != nil)
        }
    }

    @Test func resendReplacesLink() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            let firstMail = try #require(fake.sent.first)
            let first = try #require(token(in: firstMail))
            let neu = try #require(try await user(app, "neu"))
            try await app.testing().test(.POST, "/admin/users/\(neu.requireID())/invite", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Einladung an n•••@x.de gesendet."))
            }
            #expect(fake.sent.count == 2)
            let second = try #require(token(in: fake.sent[1]))
            let tokens = PasswordTokenService(db: app.db)
            #expect(try await tokens.lookup(first) == nil)
            #expect(try await tokens.lookup(second) != nil)
        }
    }

    @Test func resendRejected() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await admin(app)
            let pat = try await createUser(app, "pat")
            try await app.testing().test(.POST, "/admin/users/\(pat.requireID())/invite", headers: headers) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Das Konto hat schon ein Passwort."))
            }
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            let neu = try #require(try await user(app, "neu"))
            fake.failure = Self.failure
            try await app.testing().test(.POST, "/admin/users/\(neu.requireID())/invite", headers: headers) { res async in
                #expect(res.status == .badGateway)
                #expect(res.body.string.contains("Mailserver nicht erreichbar (refused)."))
            }
            try await MailSettingsService(db: app.db, cipher: app.tokenCipher).delete()
            try await app.testing().test(.POST, "/admin/users/\(neu.requireID())/invite", headers: headers) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(Self.mailOffError))
            }
        }
    }

    @Test func adminSeesOnlyMask() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.body.string.contains("n•••@x.de"))
                #expect(!res.body.string.contains("neu@x.de"))
            }
            let chef = try await createUser(app, "chef", isAdmin: true)
            let token = try await apiToken(app, chef)
            try await app.testing().test(.GET, "/api/v1/admin/users", headers: .bearer(token)) { res async in
                #expect(res.body.string.contains("n•••@x.de"))
                #expect(!res.body.string.contains("neu@x.de"))
            }
        }
    }

    @Test func listShowsInviteState() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            let alt = User(username: "alt", passwordHash: User.noPasswordHash, isAdmin: false)
            try await alt.save(on: app.db)
            _ = try await PasswordTokenService(db: app.db).issue(userID: alt.requireID(), purpose: .invite,
                                                                  now: Date().addingTimeInterval(-8 * 86_400))
            let expiry = CalendarDay.display(CalendarDay.today(now: Date().addingTimeInterval(7 * 86_400)))
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.body.string.contains("Einladung offen (bis \(expiry))"))
                #expect(res.body.string.contains("Einladung abgelaufen"))
            }
            let rows = try await app.userAdmin.list()
            #expect(rows.first { $0.user.username == "admin" }?.invite == InviteState.none)
            #expect(rows.first { $0.user.username == "alt" }?.invite == .expired)
        }
    }

    @Test func adminPasswordEndsInvite() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            let neu = try #require(try await user(app, "neu"))
            try await app.testing().test(.POST, "/admin/users/\(neu.requireID())/password", headers: headers, beforeRequest: { req in
                try req.content.encode(PasswordForm(password: "startpasswort1"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
            })
            #expect(try await PasswordToken.query(on: app.db).count() == 0)
            #expect(try await app.userAdmin.list().first { $0.user.username == "neu" }?.invite == InviteState.none)
        }
    }

    @Test func passwordAndEmail() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "pat", email: "pat@x.de", password: "startpasswort1")) { res in
                #expect(res.status == .seeOther)
            }
            #expect(fake.sent.isEmpty)
            #expect(try await user(app, "pat")?.emailState(app.tokenCipher) == .address("pat@x.de"))
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.body.string.contains("p•••@x.de"))
            }
        }
    }

    @Test func neitherPasswordNorEmail() async throws {
        try await withTestApp { app in
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "pat", email: " ")) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Bitte ein Startpasswort oder eine E-Mail-Adresse für die Einladung angeben."))
            }
            try await invite(app, headers, InviteForm(username: "pat", email: "Pat <p@x.de>")) { res in
                #expect(res.body.string.contains(EmailAddress.invalidMessage))
            }
        }
    }

    @Test func createInviteViaAPI() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            let token = try await apiToken(app, try await createUser(app, "chef", isAdmin: true))
            try await configureMail(app)
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(InviteBody(username: "neu", email: "neu@x.de"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = try res.content.decode(InviteSummaryBody.self)
                #expect(body.invitePending)
                #expect(body.emailHint == "n•••@x.de")
                #expect(body.inviteExpiresAt != nil)
                #expect(body.inviteMailError == nil)
            })
            fake.failure = Self.failure
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(InviteBody(username: "zwei", email: "zwei@x.de"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                #expect(try res.content.decode(InviteSummaryBody.self).inviteMailError == Self.failure.message)
            })
        }
    }

    @Test func resendInviteAPI() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            let token = try await apiToken(app, try await createUser(app, "chef", isAdmin: true))
            try await configureMail(app)
            let headers = try await admin(app)
            try await invite(app, headers, InviteForm(username: "neu", email: "neu@x.de")) { _ in }
            let id = try #require(try await user(app, "neu")).requireID()
            try await app.testing().test(.POST, "/api/v1/admin/users/\(id)/invite", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(InviteSummaryBody.self).invitePending)
            }
            fake.failure = Self.failure
            try await app.testing().test(.POST, "/api/v1/admin/users/\(id)/invite", headers: .bearer(token)) { res async throws in
                #expect(res.status == .badGateway)
                #expect(try res.content.decode(APIErrorBody.self).code == "mailFailed")
            }
            try await MailSettingsService(db: app.db, cipher: app.tokenCipher).delete()
            try await app.testing().test(.POST, "/api/v1/admin/users/\(id)/invite", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).code == "mailNotConfigured")
            }
        }
    }
}
