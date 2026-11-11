@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Every login starts a new session ID, so an ID planted in the browser beforehand (session fixation, e.g. a cookie
/// set by another service on the same host) never becomes a signed-in session.
@Suite("SessionRotation")
struct SessionRotationTests {
    static let cookieName = "watchswifty_session"

    /// An anonymous session the way an attacker gets one: any request with an unknown session cookie creates one.
    func plantedSession(_ app: Application) async throws -> String {
        let page = try await browserGet(app, "/login", headers: HTTPHeaders.sameOrigin.settingCookie(Self.cookieName, "planted"))
        let id = try #require(sessionID(page.headers))
        #expect(id != "planted")
        return id
    }

    func sessionID(_ headers: HTTPHeaders) -> String? {
        (headers.first(name: .cookie) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(Self.cookieName + "=") }.map { String($0.dropFirst(Self.cookieName.count + 1)) }
    }

    func isSignedIn(_ app: Application, session: String) async throws -> Bool {
        let home = try await browserGet(app, "/", headers: HTTPHeaders.sameOrigin.settingCookie(Self.cookieName, session))
        return home.status == .ok
    }

    @Test func passwordLoginStartsNewSession() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let planted = try await plantedSession(app)
            let result = try await browserPost(app, "/login", form: ["username": "pat", "password": "password123"],
                                               headers: HTTPHeaders.sameOrigin.settingCookie(Self.cookieName, planted))
            #expect(result.status == .seeOther)
            let fresh = try #require(sessionID(result.headers))
            #expect(fresh != planted)
            #expect(try await isSignedIn(app, session: fresh))
            #expect(try await isSignedIn(app, session: planted) == false)
        }
    }

    @Test func oidcLoginStartsNewSession() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let anna = try await createUser(app, "anna")
            try await linkOIDC(app, anna)
            let planted = try await plantedSession(app)
            let flow = try await oidcFlow(app, fake, headers: HTTPHeaders.sameOrigin.settingCookie(Self.cookieName, planted))
            #expect(flow.status == .seeOther)
            #expect(flow.location == "/")
            let fresh = try #require(sessionID(flow.headers))
            #expect(fresh != planted)
            #expect(try await isSignedIn(app, session: fresh))
            #expect(try await isSignedIn(app, session: planted) == false)
        }
    }

    @Test func passwordResetStartsNewSession() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let token = try await PasswordTokenService(db: app.db).issue(userID: pat.requireID(), purpose: .reset)
            let planted = try await plantedSession(app)
            let result = try await browserPost(app, "/reset-password",
                                               form: ["token": token, "password": "neues-passwort1", "passwordRepeat": "neues-passwort1"],
                                               headers: HTTPHeaders.sameOrigin.settingCookie(Self.cookieName, planted))
            #expect(result.status == .seeOther)
            let fresh = try #require(sessionID(result.headers))
            #expect(fresh != planted)
            #expect(try await isSignedIn(app, session: fresh))
            #expect(try await isSignedIn(app, session: planted) == false)
        }
    }
}
