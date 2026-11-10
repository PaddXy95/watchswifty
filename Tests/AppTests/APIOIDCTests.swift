@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

private struct MeFlags: Decodable { let username: String; let hasPassword: Bool; let ssoLinked: Bool; let passwordLogin: Bool }
private struct SummaryFlags: Decodable { let username: String; let invitePending: Bool; let ssoLinked: Bool }
private struct SSOLinkBody: Decodable { let mailed: Bool; let emailHint: String?; let url: String?; let mailError: String? }
private struct OIDCPasswordChangeBody: Content { var currentPassword: String; var newPassword: String }
private struct OIDCEmailChangeBody: Content { var email: String; var currentPassword: String }

@Suite("APIOIDC")
struct APIOIDCTests {
    private func ssoOnlyUser(_ app: Application, _ name: String = "anna") async throws -> User {
        let user = User(username: name, passwordHash: User.noPasswordHash, isAdmin: false)
        try await user.save(on: app.db)
        try await linkOIDC(app, user)
        return user
    }

    private func adminToken(_ app: Application) async throws -> (User, String) {
        let chef = try await createUser(app, "chef", isAdmin: true)
        return (chef, try await apiToken(app, chef))
    }

    @Test func meReportsSSOFlags() async throws {
        for passwordLogin in [true, false] {
            var config = AppConfig.testingOIDC
            config.passwordLogin = passwordLogin
            try await withTestApp(config: config) { app in
                let token = try await apiToken(app, try await ssoOnlyUser(app))
                try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                    #expect(res.status == .ok)
                    let me = try res.content.decode(MeFlags.self)
                    #expect(me.ssoLinked)
                    #expect(!me.hasPassword)
                    #expect(me.passwordLogin == passwordLogin)
                }
            }
        }
    }

    @Test func meWithoutOIDC() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await createUser(app, "anna"))
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                let me = try res.content.decode(MeFlags.self)
                #expect(!me.ssoLinked)
                #expect(me.passwordLogin)
                #expect(me.hasPassword)
            }
        }
    }

    @Test func userSummaryHasSSOLinked() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            _ = try await ssoOnlyUser(app)
            let (_, token) = try await adminToken(app)
            try await app.testing().test(.GET, "/api/v1/admin/users", headers: .bearer(token)) { res async throws in
                let users = try res.content.decode([SummaryFlags].self)
                let anna = try #require(users.first { $0.username == "anna" })
                #expect(anna.ssoLinked)
                #expect(!anna.invitePending)
                #expect(users.first { $0.username == "chef" }?.ssoLinked == false)
            }
        }
    }

    @Test func changePasswordDisabled() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config) { app in
            let token = try await apiToken(app, try await createUser(app, "anna"))
            try await app.testing().test(.PUT, "/api/v1/me/password", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(OIDCPasswordChangeBody(currentPassword: "password123", newPassword: "newpassword1"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                #expect(try res.content.decode(APIErrorBody.self).code == "passwordLoginDisabled")
            })
        }
    }

    @Test func createUserWithPasswordDisabled() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config) { app in
            let (_, token) = try await adminToken(app)
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NewUserBody(username: "bert", password: "password123", isAdmin: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                #expect(try res.content.decode(APIErrorBody.self).code == "passwordLoginDisabled")
            })
        }
    }

    @Test func resetUserPasswordDisabled() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        try await withTestApp(config: config) { app in
            let (_, token) = try await adminToken(app)
            let other = try await createUser(app, "bert")
            try await app.testing().test(.PUT, "/api/v1/admin/users/\(try other.requireID())/password", headers: .bearer(token),
                                         beforeRequest: { req in
                try req.content.encode(AdminPasswordBody(password: "newpassword1"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                #expect(try res.content.decode(APIErrorBody.self).code == "passwordLoginDisabled")
            })
        }
    }

    @Test func setEmailFromProvider() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let token = try await apiToken(app, try await ssoOnlyUser(app))
            try await app.testing().test(.PUT, "/api/v1/me/email", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(OIDCEmailChangeBody(email: "x@example.org", currentPassword: ""), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
                let error = try res.content.decode(APIErrorBody.self)
                #expect(error.code == "emailFromProvider")
                #expect(error.message == "Die Adresse kommt von SSO – bitte dort ändern.")
            })
        }
    }

    @Test func createSSOLinkReturnsURLWithoutMail() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let (_, token) = try await adminToken(app)
            let other = try await createUser(app, "bert")
            try await app.testing().test(.POST, "/api/v1/admin/users/\(try other.requireID())/sso-link", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(SSOLinkBody.self)
                #expect(!body.mailed)
                #expect(body.url?.hasPrefix("http://localhost:8080/auth/oidc/start?link=") == true)
            }
        }
    }

    @Test func createSSOLinkMails() async throws {
        let mail = FakeMailSender()
        try await withTestApp(config: .testingOIDC, mail: mail) { app in
            try await configureMail(app)
            let (_, token) = try await adminToken(app)
            let other = try await createUser(app, "bert")
            other.email = try app.tokenCipher.seal("bert@example.org")
            try await other.save(on: app.db)
            try await app.testing().test(.POST, "/api/v1/admin/users/\(try other.requireID())/sso-link", headers: .bearer(token)) { res async throws in
                let body = try res.content.decode(SSOLinkBody.self)
                #expect(body.mailed)
                #expect(body.url == nil)
                #expect(body.emailHint == "b•••@example.org")
            }
            #expect(mail.sent.last?.to == "bert@example.org")
        }
    }

    @Test func createSSOLinkSelfAndWithoutOIDC() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let (chef, token) = try await adminToken(app)
            try await app.testing().test(.POST, "/api/v1/admin/users/\(try chef.requireID())/sso-link", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).code == "selfAction")
            }
        }
        try await withTestApp { app in
            let (_, token) = try await adminToken(app)
            let other = try await createUser(app, "bert")
            try await app.testing().test(.POST, "/api/v1/admin/users/\(try other.requireID())/sso-link", headers: .bearer(token)) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}
