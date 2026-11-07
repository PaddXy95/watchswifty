@testable import App
import Fluent
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

struct TokenForm: Content { var token: String }

@Suite("AccountToken")
struct AccountTokenTests {
    @Test func saveTokenValidatesAndStoresMasked() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(res.body.string.contains("Kein TMDB-Token hinterlegt"))
            }
            try await app.testing().test(.POST, "/account/tmdb-token", headers: headers, beforeRequest: { req in
                try req.content.encode(TokenForm(token: "  eyJsecret-token-abcd  "), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("TMDB-Token gespeichert."))
                #expect(res.body.string.contains("…abcd"))
                #expect(!res.body.string.contains("eyJsecret-token-abcd"))
            })
            #expect(tmdb.calls.contains("validate"))
            let reloaded = try await User.find(user.requireID(), on: app.db)
            #expect(reloaded?.tmdbToken?.hasPrefix("enc:v1:") == true)   // encrypted at rest
            #expect(app.tokenCipher.open(reloaded?.tmdbToken) == "eyJsecret-token-abcd")
        }
    }

    @Test func rejectedTokenNotStored() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .unauthorized
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/tmdb-token", headers: headers, beforeRequest: { req in
                try req.content.encode(TokenForm(token: "wrong"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("TMDB hat den Token abgelehnt."))
            })
            #expect(try await User.find(user.requireID(), on: app.db)?.tmdbToken == nil)
        }
    }

    @Test func removeToken() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/tmdb-token/remove", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("TMDB-Token entfernt."))
            }
            #expect(try await User.find(user.requireID(), on: app.db)?.tmdbToken == nil)
        }
    }

    @Test func adminPageNeverShowsTokens() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat", tmdbToken: "very-secret-token-1234")
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.GET, "/admin/users", headers: headers) { res async in
                #expect(!res.body.string.contains("very-secret-token"))
                #expect(!res.body.string.contains("1234"))
            }
        }
    }
}

@Suite("TokenHelp")
struct TokenHelpTests {
    @Test func accountExplainsTokenSteps() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat", tmdbToken: nil)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains("So bekommst du einen TMDB-Token"))
                #expect(body.contains(#"href="https://www.themoviedb.org/signup""#))
                #expect(body.contains(#"href="https://www.themoviedb.org/settings/api""#))
                #expect(body.contains("API Read Access Token"))
                #expect(body.contains(#"<details class="token-help" open"#))
            }
        }
    }
}
