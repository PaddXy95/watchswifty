@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct ResetForm: Content { var token: String; var password: String; var passwordRepeat: String }

@Suite("PasswordReset")
struct PasswordResetTests {
    static let invalidText = "Der Link ist ungültig oder abgelaufen. Fordere unter „Passwort vergessen“ einen neuen an."
    static let expiredInviteText = "Die Einladung ist abgelaufen – bitte wende dich an deinen Admin."

    func tokens(_ app: Application) -> PasswordTokenService { PasswordTokenService(db: app.db) }

    func post(_ app: Application, token: String, password: String = "neues-passwort1", repeat again: String? = nil,
              _ check: @escaping @Sendable (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "/reset-password", headers: .sameOrigin, beforeRequest: { req in
            try req.content.encode(ResetForm(token: token, password: password, passwordRepeat: again ?? password), as: .urlEncodedForm)
        }, afterResponse: check)
    }

    @Test func onlyHashStored() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            #expect(token.count == 43)
            #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
            let row = try #require(try await PasswordToken.query(on: app.db).first())
            #expect(row.tokenHash == APITokenService.hash(token))
            #expect(row.tokenHash != token)
            #expect(row.expiresAt.timeIntervalSince(row.createdAt) == 3600)
        }
    }

    @Test func getDoesNotConsumeToken() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            for _ in 1...2 {
                try await app.testing().test(.GET, "/reset-password?token=\(token)") { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("name=\"passwordRepeat\""))
                }
            }
            #expect(try await tokens(app).lookup(token) != nil)
        }
    }

    @Test func pageHeaders() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            try await app.testing().test(.GET, "/reset-password?token=\(token)") { res async in
                #expect(res.headers.first(name: "Referrer-Policy") == "no-referrer")
                #expect(res.headers.first(name: .cacheControl) == "no-store")
            }
        }
    }

    @Test func resetSetsPasswordAndLogsIn() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            try await post(app, token: token) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
                #expect(res.headers.first(name: .setCookie)?.contains("watchswifty_session=") == true)
            }
            _ = try await login(app, "pat", password: "neues-passwort1")
            #expect(try await PasswordToken.query(on: app.db).count() == 0)
        }
    }

    @Test func inviteGoesToAccount() async throws {
        try await withTestApp { app in
            let neu = User(username: "neu", passwordHash: User.noPasswordHash, isAdmin: false)
            try await neu.save(on: app.db)
            let token = try await tokens(app).issue(userID: neu.requireID(), purpose: .invite)
            try await post(app, token: token) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/account?welcome=1")
            }
            let headers = try await login(app, "neu", password: "neues-passwort1")
            try await app.testing().test(.GET, "/account?welcome=1", headers: headers) { res async in
                #expect(res.body.string.contains("Willkommen – trag hier deinen TMDB-Token ein."))
            }
        }
    }

    @Test func expiredAndUsedRejected() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let old = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset, now: Date().addingTimeInterval(-3601))
            try await app.testing().test(.GET, "/reset-password?token=\(old)") { res async in
                #expect(res.body.string.contains(Self.invalidText))
                #expect(!res.body.string.contains("name=\"passwordRepeat\""))
            }
            try await post(app, token: old) { res in
                #expect(res.body.string.contains(Self.invalidText))
            }
            _ = try await login(app, "pat")

            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            try await post(app, token: token) { res in #expect(res.status == .seeOther) }
            try await post(app, token: token, password: "drittes-passwort") { res in
                #expect(res.body.string.contains(Self.invalidText))
            }

            let neu = User(username: "neu", passwordHash: User.noPasswordHash, isAdmin: false)
            try await neu.save(on: app.db)
            let invite = try await tokens(app).issue(userID: neu.requireID(), purpose: .invite,
                                                     now: Date().addingTimeInterval(-7 * 86_400 - 1))
            try await app.testing().test(.GET, "/reset-password?token=\(invite)") { res async in
                #expect(res.body.string.contains(Self.expiredInviteText))
            }
            try await app.testing().test(.GET, "/reset-password?token=nonsense") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(Self.invalidText))
            }
        }
    }

    @Test func newTokenReplacesOld() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let first = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            let second = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            #expect(try await tokens(app).lookup(first) == nil)
            #expect(try await tokens(app).lookup(second) != nil)
            _ = try await tokens(app).issue(userID: pat.requireID(), purpose: .invite)
            #expect(try await tokens(app).lookup(second) != nil)
        }
    }

    @Test func passwordRules() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset)
            try await post(app, token: token, repeat: "anderes-passwort") { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Die Passwörter stimmen nicht überein."))
                #expect(res.body.string.contains("name=\"passwordRepeat\""))
            }
            try await post(app, token: token, password: "kurz") { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(AccountValidation.passwordMessage))
            }
            #expect(try await tokens(app).lookup(token) != nil)
        }
    }

    @Test func tokensGoWithUser() async throws {
        try await withTestApp { app in
            let admin = try #require(try await User.query(on: app.db).filter(\.$username == "admin").first())
            let neu = User(username: "neu", passwordHash: User.noPasswordHash, isAdmin: false)
            try await neu.save(on: app.db)
            let token = try await tokens(app).issue(userID: neu.requireID(), purpose: .invite)
            try await app.userAdmin.delete(id: neu.requireID(), actingUserID: admin.requireID())
            #expect(try await PasswordToken.query(on: app.db).count() == 0)
            try await app.testing().test(.GET, "/reset-password?token=\(token)") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(Self.invalidText))
            }
        }
    }

    @Test func deleteExpiredCount() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let neu = try await createUser(app, "neu")
            let past = Date().addingTimeInterval(-8 * 86_400)
            _ = try await tokens(app).issue(userID: pat.requireID(), purpose: .reset, now: past)
            _ = try await tokens(app).issue(userID: neu.requireID(), purpose: .invite, now: past)
            _ = try await tokens(app).issue(userID: neu.requireID(), purpose: .reset)
            #expect(try await tokens(app).deleteExpired() == 2)
            #expect(try await PasswordToken.query(on: app.db).count() == 1)
        }
    }
}
