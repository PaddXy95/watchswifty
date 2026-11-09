@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct MailSettingsBody: Codable {
    let configured: Bool
    let unreadable: Bool
    let host: String?
    let port: Int?
    let encryption: String?
    let username: String?
    let hasPassword: Bool
    let fromAddress: String?
    let baseUrl: String?
}

struct MailUpdateBody: Content {
    var host = "relay.test"
    var port: Int? = 2525
    var encryption = "starttls"
    var username: String? = "watchswifty"
    var password: String? = "relay-secret"
    var fromAddress = "noreply@example.org"
    var fromName: String? = nil
    var caFile: String? = nil
    var baseUrl = "https://watch.example.lan"
}

@Suite("APIMail")
struct APIMailTests {
    func adminToken(_ app: Application) async throws -> String {
        try await apiToken(app, try await createUser(app, "chef", isAdmin: true))
    }

    @Test func nonAdminForbidden() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await createUser(app, "pat"))
            try await app.testing().test(.GET, "/api/v1/admin/mail", headers: .bearer(token)) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func getHidesPassword() async throws {
        try await withTestApp { app in
            let token = try await adminToken(app)
            try await app.testing().test(.GET, "/api/v1/admin/mail", headers: .bearer(token)) { res async throws in
                let body = try res.content.decode(MailSettingsBody.self)
                #expect(body.configured == false)
                #expect(body.hasPassword == false)
            }
            try await app.testing().test(.PUT, "/api/v1/admin/mail", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(MailUpdateBody(), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("relay-secret"))
                let body = try res.content.decode(MailSettingsBody.self)
                #expect(body.configured && body.hasPassword)
                #expect(body.host == "relay.test" && body.port == 2525 && body.encryption == "starttls")
            })
            try await app.testing().test(.GET, "/api/v1/admin/mail", headers: .bearer(token)) { res async throws in
                #expect(!res.body.string.contains("relay-secret"))
                #expect(try res.content.decode(MailSettingsBody.self).baseUrl == "https://watch.example.lan")
            }
        }
    }

    @Test func putValidation() async throws {
        try await withTestApp { app in
            let token = try await adminToken(app)
            try await MailSettingsService(db: app.db, cipher: app.tokenCipher).save(mailInput())
            var update = MailUpdateBody()
            update.host = "evil.test"
            update.password = nil
            try await app.testing().test(.PUT, "/api/v1/admin/mail", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(update, as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                let error = try res.content.decode(APIErrorBody.self)
                #expect(error.code == "validation")
                #expect(error.message == MailSettingsService.passwordReentryMessage)
            })
        }
    }

    @Test func testWithoutConfigIs422() async throws {
        try await withTestApp { app in
            let token = try await adminToken(app)
            try await app.testing().test(.POST, "/api/v1/admin/mail/test", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(TestMailForm(to: "p@x.de"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).code == "mailNotConfigured")
            })
        }
    }

    @Test func testSentAndFailure() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            let token = try await adminToken(app)
            try await configureMail(app)
            try await app.testing().test(.POST, "/api/v1/admin/mail/test", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(TestMailForm(to: "p@x.de"), as: .json)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            #expect(fake.sent.count == 1)
            fake.failure = MailError(message: "Mailserver nicht erreichbar (refused).")
            try await app.testing().test(.POST, "/api/v1/admin/mail/test", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(TestMailForm(to: "p@x.de"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .badGateway)
                let error = try res.content.decode(APIErrorBody.self)
                #expect(error.code == "mailFailed")
                #expect(error.message == "Mailserver nicht erreichbar (refused).")
            })
        }
    }

    @Test func deleteIs204() async throws {
        try await withTestApp { app in
            let token = try await adminToken(app)
            try await configureMail(app)
            try await app.testing().test(.DELETE, "/api/v1/admin/mail", headers: .bearer(token)) { res async in
                #expect(res.status == .noContent)
            }
            #expect(try await MailSettingsService(db: app.db, cipher: app.tokenCipher).state() == MailSettingsState.notConfigured)
        }
    }
}
