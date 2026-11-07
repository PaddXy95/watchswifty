@testable import App
import Testing
import VaporTesting

struct ChangePasswordForm: Content { var currentPassword: String; var newPassword: String }

@Suite("Account")
struct AccountTests {
    @Test func accountPageRenders() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Passwort ändern"))
            }
        }
    }

    @Test func changeOwnPasswordRequiresCurrent() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/password", headers: headers, beforeRequest: { req in
                try req.content.encode(ChangePasswordForm(currentPassword: "wrong-one", newPassword: "newpassword1"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Aktuelles Passwort ist falsch."))
            })
            try await app.testing().test(.POST, "/account/password", headers: headers, beforeRequest: { req in
                try req.content.encode(ChangePasswordForm(currentPassword: "password123", newPassword: "newpassword1"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Passwort geändert."))
            })
            _ = try await login(app, "pat", password: "newpassword1")
        }
    }

    @Test func newPasswordTooShort() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/password", headers: headers, beforeRequest: { req in
                try req.content.encode(ChangePasswordForm(currentPassword: "password123", newPassword: "short"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Passwort muss mindestens 8 Zeichen haben."))
            })
        }
    }
}
