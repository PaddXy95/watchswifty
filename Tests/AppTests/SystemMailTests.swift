@testable import App
import Crypto
import Fluent
import Testing
import VaporTesting

struct TestMailForm: Content { var to: String }

@Suite("SystemMail")
struct SystemMailTests {
    func adminHeaders(_ app: Application) async throws -> HTTPHeaders {
        try await login(app, "admin", password: "adminpass123")
    }

    @Test func mailSectionForAdminsOnly() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/admin/system/mail", headers: headers, beforeRequest: { req in
                try req.content.encode(mailInput(), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            #expect(try await MailSettingsService(db: app.db, cipher: app.tokenCipher).state() == MailSettingsState.notConfigured)
        }
    }

    @Test func saveShowsSettingsWithoutPassword() async throws {
        try await withTestApp { app in
            let headers = try await adminHeaders(app)
            try await app.testing().test(.POST, "/admin/system/mail", headers: headers, beforeRequest: { req in
                try req.content.encode(mailInput(), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("E-Mail-Einstellungen gespeichert."))
                #expect(res.body.string.contains("relay.test"))
                #expect(res.body.string.contains("gespeichert"))
                #expect(!res.body.string.contains("relay-secret"))
            })
            try await app.testing().test(.GET, "/admin/system", headers: headers) { res async in
                #expect(res.body.string.contains("relay.test"))
                #expect(!res.body.string.contains("relay-secret"))
            }
        }
    }

    @Test func saveErrorShown() async throws {
        try await withTestApp { app in
            let headers = try await adminHeaders(app)
            try await app.testing().test(.POST, "/admin/system/mail", headers: headers, beforeRequest: { req in
                try req.content.encode(mailInput(baseURL: "https://x/app"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(MailSettingsService.baseURLMessage))
            })
        }
    }

    @Test func prefillsBaseURLFromRequest() async throws {
        try await withTestApp { app in
            var headers = try await adminHeaders(app)
            headers.replaceOrAdd(name: .host, value: "nas.lan:8080")
            try await app.testing().test(.GET, "/admin/system", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("value=\"http://nas.lan:8080\""))
            }
            #expect(try await AppSettings.query(on: app.db).first()?.mailConfig == nil)
        }
    }

    @Test func testMailSent() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await adminHeaders(app)
            try await app.testing().test(.POST, "/admin/system/mail/test", headers: headers, beforeRequest: { req in
                try req.content.encode(TestMailForm(to: "p@x.de"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Testmail gesendet."))
            })
            #expect(fake.sent.count == 1)
        }
    }

    @Test func testMailErrorShown() async throws {
        let fake = FakeMailSender()
        fake.failure = MailError(message: "Mailserver nicht erreichbar (refused).")
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            let headers = try await adminHeaders(app)
            try await app.testing().test(.POST, "/admin/system/mail/test", headers: headers, beforeRequest: { req in
                try req.content.encode(TestMailForm(to: "p@x.de"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .serviceUnavailable)   // never 502: proxies like Cloudflare replace it
                #expect(res.body.string.contains("Mailserver nicht erreichbar (refused)."))
            })
        }
    }

    @Test func unreadableShown() async throws {
        try await withTestApp { app in
            try await MailSettingsService(db: app.db, cipher: TokenCipher(key: SymmetricKey(size: .bits256))).save(mailInput())
            let headers = try await adminHeaders(app)
            try await app.testing().test(.GET, "/admin/system", headers: headers) { res async in
                #expect(res.body.string.contains("E-Mail-Einstellungen nicht lesbar – bitte neu eintragen."))
            }
        }
    }

    @Test func deleteMail() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let headers = try await adminHeaders(app)
            try await app.testing().test(.POST, "/admin/system/mail/delete", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("E-Mail-Einstellungen gelöscht."))
            }
            #expect(try await MailSettingsService(db: app.db, cipher: app.tokenCipher).state() == MailSettingsState.notConfigured)
        }
    }
}
