@testable import App
import Fluent
import Testing
import VaporTesting

struct NewUserForm: Content { var username: String; var password: String; var isAdmin: Bool }
struct PasswordForm: Content { var password: String }
struct AdminFlagForm: Content { var isAdmin: Bool }

@Suite("Admin")
struct AdminTests {
    @Test func nonAdminGets403() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func adminSeesUserList() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("pat"))
                #expect(res.body.string.contains("Admin"))
            }
        }
    }

    @Test func adminCreatesUserWhoCanLogIn() async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/admin/users", headers: headers, beforeRequest: { req in
                try req.content.encode(NewUserForm(username: "Pat", password: "password123", isAdmin: false), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
            })
            let created = try await User.query(on: app.db).filter(\.$username == "pat").first()
            #expect(created?.isAdmin == false)
            _ = try await login(app, "pat")
        }
    }

    @Test func duplicateUsernameRejected() async throws {
        try await expectCreateError(username: "admin", password: "password123", message: "Benutzername ist vergeben.")
    }

    @Test func invalidUsernameRejected() async throws {
        try await expectCreateError(username: "a", password: "password123", message: "Benutzername: 3–32 Zeichen, nur a–z, 0–9, . _ -")
        try await expectCreateError(username: "hans wurst", password: "password123", message: "Benutzername: 3–32 Zeichen, nur a–z, 0–9, . _ -")
    }

    @Test func shortPasswordRejected() async throws {
        try await expectCreateError(username: "pat", password: "short", message: "Passwort muss mindestens 8 Zeichen haben.")
    }

    @Test func resetPasswordReplacesOld() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/admin/users/\(pat.requireID())/password", headers: headers, beforeRequest: { req in
                try req.content.encode(PasswordForm(password: "newpassword1"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
            })
            try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(LoginForm(username: "pat", password: "password123"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains("Benutzername oder Passwort falsch."))
            })
            _ = try await login(app, "pat", password: "newpassword1")
        }
    }

    @Test func toggleAdmin() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/admin/users/\(pat.requireID())/admin", headers: headers, beforeRequest: { req in
                try req.content.encode(AdminFlagForm(isAdmin: true), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
            })
            let reloaded = try await User.find(pat.requireID(), on: app.db)
            #expect(reloaded?.isAdmin == true)
        }
    }

    @Test func lastAdminCannotBeDemoted() async throws {
        try await withTestApp { app in
            let admin = try #require(try await User.query(on: app.db).first())
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/admin/users/\(admin.requireID())/admin", headers: headers, beforeRequest: { req in
                try req.content.encode(AdminFlagForm(isAdmin: false), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Der letzte Admin kann nicht entfernt werden."))
            })
            let reloaded = try await User.find(admin.requireID(), on: app.db)
            #expect(reloaded?.isAdmin == true)
        }
    }

    @Test func adminCannotDeleteSelf() async throws {
        try await withTestApp { app in
            let admin = try #require(try await User.query(on: app.db).first())
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.DELETE, "/admin/users/\(admin.requireID())", headers: headers.adding(.htmx)) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Du kannst dich nicht selbst löschen."))
            }
            let count = try await User.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test func deleteUserRemovesAccount() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.DELETE, "/admin/users/\(pat.requireID())", headers: headers.adding(.htmx)) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Konto gelöscht."))
            }
            let gone = try await User.find(pat.requireID(), on: app.db)
            #expect(gone == nil)
        }
    }

    private func expectCreateError(username: String, password: String, message: String) async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/admin/users", headers: headers, beforeRequest: { req in
                try req.content.encode(NewUserForm(username: username, password: password, isAdmin: false), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains(message))
            })
        }
    }
}
