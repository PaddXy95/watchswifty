@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct ConfirmedNewUserBody: Content { var username: String; var password: String; var isAdmin: Bool; var currentPassword: String? }
struct ConfirmedAdminFlagBody: Content { var isAdmin: Bool; var currentPassword: String? }
struct ConfirmedPasswordBody: Content { var password: String; var currentPassword: String? }
struct ConfirmationBody: Content { var currentPassword: String? }

/// Granting admin rights, and setting the password of or a linking link for another admin, need the acting admin's
/// confirmation, so a stolen admin device or session cannot mint or take over a peer admin who then acts on the
/// owner's account (security audit F10). The App API takes the current password with the request; the web asks once
/// for five minutes (password or provider).
@Suite("AdminConfirmation")
struct AdminConfirmationTests {
    /// Admin "chef" (password "password123") and a device token for them.
    func chef(_ app: Application) async throws -> (User, HTTPHeaders) {
        let chef = try await createUser(app, "chef", isAdmin: true)
        return (chef, .bearer(try await apiToken(app, chef)))
    }

    func send<Body: Content>(_ app: Application, _ method: HTTPMethod, _ path: String, _ headers: HTTPHeaders,
                             _ body: Body) async throws -> (HTTPStatus, String?) {
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.testing().test(method, path, headers: headers, beforeRequest: { req in
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(APIErrorBody.self).code)
        })
        return result
    }

    func isAdmin(_ app: Application, _ username: String) async throws -> Bool? {
        try await User.query(on: app.db).filter(\.$username == username).first()?.isAdmin
    }

    // MARK: App API

    @Test func apiCreatingAnAdminNeedsThePassword() async throws {
        try await withTestApp { app in
            let (_, token) = try await chef(app)
            for confirmation in [nil, "falsch12345"] {
                let (status, code) = try await send(app, .POST, "/api/v1/admin/users", token,
                                                    ConfirmedNewUserBody(username: "helfer", password: "helferpass1", isAdmin: true,
                                                                         currentPassword: confirmation))
                #expect(status == .forbidden)
                #expect(code == "confirmationRequired")
            }
            #expect(try await isAdmin(app, "helfer") == nil)
            let (status, _) = try await send(app, .POST, "/api/v1/admin/users", token,
                                             ConfirmedNewUserBody(username: "helfer", password: "helferpass1", isAdmin: true,
                                                                  currentPassword: "password123"))
            #expect(status == .created)
            #expect(try await isAdmin(app, "helfer") == true)
            let (plain, _) = try await send(app, .POST, "/api/v1/admin/users", token,
                                            ConfirmedNewUserBody(username: "pat", password: "patpasswort", isAdmin: false, currentPassword: nil))
            #expect(plain == .created)
        }
    }

    @Test func apiPromotionNeedsThePasswordDemotionDoesNot() async throws {
        try await withTestApp { app in
            let (_, token) = try await chef(app)
            let pat = try await createUser(app, "pat")
            let path = "/api/v1/admin/users/\(try pat.requireID())/admin"
            #expect(try await send(app, .PUT, path, token, ConfirmedAdminFlagBody(isAdmin: true, currentPassword: nil)).1 == "confirmationRequired")
            #expect(try await isAdmin(app, "pat") == false)
            #expect(try await send(app, .PUT, path, token, ConfirmedAdminFlagBody(isAdmin: true, currentPassword: "password123")).0 == .ok)
            #expect(try await isAdmin(app, "pat") == true)
            #expect(try await send(app, .PUT, path, token, ConfirmedAdminFlagBody(isAdmin: false, currentPassword: nil)).0 == .ok)
            #expect(try await isAdmin(app, "pat") == false)
        }
    }

    @Test func apiPasswordOfAnotherAdminNeedsThePassword() async throws {
        try await withTestApp { app in
            let (_, token) = try await chef(app)
            let boss = try await createUser(app, "boss", isAdmin: true)
            let pat = try await createUser(app, "pat")
            let bossPath = "/api/v1/admin/users/\(try boss.requireID())/password"
            let refused = try await send(app, .PUT, bossPath, token, ConfirmedPasswordBody(password: "uebernommen1", currentPassword: nil))
            #expect(refused.0 == .forbidden)
            #expect(refused.1 == "confirmationRequired")
            _ = try await login(app, "boss")   // old password still works
            #expect(try await send(app, .PUT, bossPath, token,
                                   ConfirmedPasswordBody(password: "neuespasswort", currentPassword: "password123")).0 == .noContent)
            #expect(try await send(app, .PUT, "/api/v1/admin/users/\(try pat.requireID())/password", token,
                                   ConfirmedPasswordBody(password: "neuespasswort", currentPassword: nil)).0 == .noContent)
        }
    }

    @Test func apiLinkingLinkForAnotherAdminNeedsThePassword() async throws {
        try await withTestApp(config: .testingOIDC, oidc: FakeOIDCProvider()) { app in
            let (_, token) = try await chef(app)
            let boss = try await createUser(app, "boss", isAdmin: true)
            let pat = try await createUser(app, "pat")
            let bossPath = "/api/v1/admin/users/\(try boss.requireID())/sso-link"
            #expect(try await send(app, .POST, bossPath, token, ConfirmationBody(currentPassword: nil)).1 == "confirmationRequired")
            #expect(try await OIDCLinkToken.query(on: app.db).count() == 0)
            #expect(try await send(app, .POST, bossPath, token, ConfirmationBody(currentPassword: "password123")).0 == .ok)
            try await app.testing().test(.POST, "/api/v1/admin/users/\(try pat.requireID())/sso-link", headers: token) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func apiAdminWithoutPasswordConfirmsInTheBrowser() async throws {
        try await withTestApp(config: .testingOIDC, oidc: FakeOIDCProvider()) { app in
            let anna = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: true)
            try await anna.save(on: app.db)
            try await linkOIDC(app, anna)
            let token = HTTPHeaders.bearer(try await apiToken(app, anna))
            let (status, code) = try await send(app, .POST, "/api/v1/admin/users", token,
                                                ConfirmedNewUserBody(username: "helfer", password: "helferpass1", isAdmin: true,
                                                                     currentPassword: "irgendwas1"))
            #expect(status == .forbidden)
            #expect(code == "confirmInBrowser")
            #expect(try await isAdmin(app, "helfer") == nil)
        }
    }

    // MARK: Web

    @Test func webGrantingAdminNeedsARecentConfirmation() async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            let pat = try await createUser(app, "pat")
            let page = try await browserGet(app, "/admin/users", headers: headers)
            #expect(page.body.contains(#"action="/admin/users/confirm""#))

            let refused = try await browserPost(app, "/admin/users", form: ["username": "helfer", "password": "helferpass1", "isAdmin": "true"],
                                                headers: headers)
            #expect(refused.status == .forbidden)
            #expect(refused.body.contains(AdminConfirmation.neededMessage))
            #expect(try await isAdmin(app, "helfer") == nil)
            let promote = try await browserPost(app, "/admin/users/\(try pat.requireID())/admin", form: ["isAdmin": "true"], headers: headers)
            #expect(promote.status == .forbidden)
            #expect(try await isAdmin(app, "pat") == false)

            let wrong = try await browserPost(app, "/admin/users/confirm", form: ["password": "falsch12345"], headers: headers)
            #expect(wrong.status == .forbidden)
            #expect(wrong.body.contains(AccountValidation.wrongCurrentPasswordMessage))
            let confirmed = try await browserPost(app, "/admin/users/confirm", form: ["password": "adminpass123"], headers: headers)
            #expect(confirmed.status == .seeOther)
            #expect(!(try await browserGet(app, "/admin/users", headers: headers)).body.contains(#"action="/admin/users/confirm""#))

            let created = try await browserPost(app, "/admin/users", form: ["username": "helfer", "password": "helferpass1", "isAdmin": "true"],
                                                headers: headers)
            #expect(created.status == .seeOther)
            #expect(try await isAdmin(app, "helfer") == true)
            #expect(try await browserPost(app, "/admin/users/\(try pat.requireID())/admin", form: ["isAdmin": "true"], headers: headers).status
                == .seeOther)
            #expect(try await isAdmin(app, "pat") == true)
        }
    }

    @Test func webActionsOnOtherAdminsNeedConfirmation() async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            let boss = try await createUser(app, "boss", isAdmin: true)
            let pat = try await createUser(app, "pat")
            let reset = try await browserPost(app, "/admin/users/\(try boss.requireID())/password", form: ["password": "uebernommen1"],
                                              headers: headers)
            #expect(reset.status == .forbidden)
            _ = try await login(app, "boss")
            #expect(try await browserPost(app, "/admin/users/\(try pat.requireID())/password", form: ["password": "neuespasswort"],
                                          headers: headers).status == .seeOther)
            #expect(try await browserPost(app, "/admin/users/\(try boss.requireID())/admin", form: ["isAdmin": "false"],
                                          headers: headers).status == .seeOther)
            #expect(try await isAdmin(app, "boss") == false)
        }
    }

    @Test func webAdminWithoutPasswordConfirmsThroughTheProvider() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let anna = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: true)
            try await anna.save(on: app.db)
            try await linkOIDC(app, anna)
            let pat = try await createUser(app, "pat")
            let signedIn = try await oidcFlow(app, fake)
            let page = try await browserGet(app, "/admin/users", headers: signedIn.headers)
            #expect(page.body.contains(#"action="/admin/users/confirm-sso""#))
            #expect(!page.body.contains(#"action="/admin/users/confirm""#))
            let promotePath = "/admin/users/\(try pat.requireID())/admin"
            #expect(try await browserPost(app, promotePath, form: ["isAdmin": "true"], headers: signedIn.headers).status == .forbidden)

            let start = try await browserPost(app, "/admin/users/confirm-sso", form: [:], headers: signedIn.headers)
            #expect(start.location == "/auth/oidc/start")
            let reauth = try await oidcFlow(app, fake, start: try #require(start.location), headers: start.headers)
            #expect(reauth.location == "/admin/users")
            #expect(try await browserPost(app, promotePath, form: ["isAdmin": "true"], headers: reauth.headers).status == .seeOther)
            #expect(try await isAdmin(app, "pat") == true)
        }
    }
}
