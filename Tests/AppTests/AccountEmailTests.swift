@testable import App
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

struct EmailForm: Content { var email: String; var currentPassword: String }
struct MeEmailBody: Codable { let username: String; let email: String? }

@Suite("AccountEmail")
struct AccountEmailTests {
    static let unreadableText = "Adresse nicht lesbar – bitte neu eintragen (der Server-Schlüssel hat sich geändert)."
    static let mailOffHint = "Der Admin hat den Mail-Versand noch nicht eingerichtet – „Passwort vergessen“ funktioniert erst danach."

    func setEmail(_ app: Application, _ headers: HTTPHeaders, _ email: String, password: String = "password123",
                  _ check: @escaping @Sendable (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "/account/email", headers: headers, beforeRequest: { req in
            try req.content.encode(EmailForm(email: email, currentPassword: password), as: .urlEncodedForm)
        }, afterResponse: check)
    }

    func user(_ app: Application, _ name: String) async throws -> User {
        try #require(try await User.query(on: app.db).filter(\.$username == name).first())
    }

    @Test func storedEncrypted() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await setEmail(app, headers, " Pat@IDESIA.de ") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("E-Mail-Adresse gespeichert."))
                #expect(res.body.string.contains("Pat@idesia.de"))
            }
            let pat = try await user(app, "pat")
            #expect(pat.email?.hasPrefix("enc:v1:") == true)
            #expect(pat.email?.contains("idesia") == false)
            #expect(pat.emailState(app.tokenCipher) == .address("Pat@idesia.de"))
        }
    }

    @Test func requiresCurrentPassword() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await setEmail(app, headers, "p@x.de", password: "falsch-falsch") { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(AccountValidation.wrongCurrentPasswordMessage))
            }
            #expect(try await user(app, "pat").emailState(app.tokenCipher) == EmailState.none)
        }
    }

    @Test func invalidEmailRejected() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            for bad in ["Pat <p@x.de>", "pä@x.de", "a b@x.de"] {
                try await setEmail(app, headers, bad) { res in
                    #expect(res.status == .unprocessableEntity)
                    #expect(res.body.string.contains(EmailAddress.invalidMessage))
                }
            }
            #expect(try await user(app, "pat").email == nil)
        }
    }

    @Test func emptyRemoves() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await setEmail(app, headers, "p@x.de") { res in #expect(res.status == .ok) }
            try await setEmail(app, headers, " ") { res in
                #expect(res.body.string.contains("E-Mail-Adresse entfernt."))
            }
            #expect(try await user(app, "pat").email == nil)
        }
    }

    @Test func changeDeletesResetTokens() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let tokens = PasswordTokenService(db: app.db)
            let reset = try await tokens.issue(userID: pat.requireID(), purpose: .reset)
            let invite = try await tokens.issue(userID: pat.requireID(), purpose: .invite)
            let headers = try await login(app, "pat")
            try await setEmail(app, headers, "p@x.de") { res in #expect(res.status == .ok) }
            #expect(try await tokens.lookup(reset) == nil)
            #expect(try await tokens.lookup(invite) != nil)
        }
    }

    @Test func unreadableShownAsNone() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            pat.email = try TokenCipher(key: SymmetricKey(size: .bits256)).seal("p@x.de")
            try await pat.save(on: app.db)
            #expect(pat.emailState(app.tokenCipher) == .unreadable)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(res.body.string.contains(Self.unreadableText))
            }
            let token = try await apiToken(app, pat)
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(MeEmailBody.self).email == nil)
            }
        }
    }

    @Test func hintWhenMailOff() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(res.body.string.contains(Self.mailOffHint))
            }
            try await configureMail(app)
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(!res.body.string.contains(Self.mailOffHint))
                #expect(res.body.string.contains("E-Mail-Adresse"))
            }
        }
    }

    @Test func apiSetEmail() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await apiToken(app, pat)
            try await app.testing().test(.PUT, "/api/v1/me/email", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(EmailForm(email: "p@X.de", currentPassword: "password123"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(MeEmailBody.self).email == "p@x.de")
            })
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(MeEmailBody.self).email == "p@x.de")
            }
            try await app.testing().test(.PUT, "/api/v1/me/email", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(EmailForm(email: "q@x.de", currentPassword: "falsch-falsch"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == AccountValidation.wrongCurrentPasswordMessage)
            })
        }
    }

    @Test func systemPrefillsAdminAddress() async throws {
        try await withTestApp { app in
            try await configureMail(app)
            let headers = try await login(app, "admin", password: "adminpass123")
            try await setEmail(app, headers, "chef@x.de", password: "adminpass123") { res in #expect(res.status == .ok) }
            try await app.testing().test(.GET, "/admin/system", headers: headers) { res async in
                #expect(res.body.string.contains("value=\"chef@x.de\""))
            }
        }
    }
}
