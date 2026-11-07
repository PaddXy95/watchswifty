@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("Auth")
struct AuthTests {
    @Test func bootstrapCreatesAdminOnlyWhenEmpty() async throws {
        try await withTestApp { app in
            let users = try await User.query(on: app.db).all()
            #expect(users.count == 1)
            #expect(users.first?.isAdmin == true)
            #expect(users.first?.username == "admin")
            try await bootstrapAdmin(config: .testing, db: app.db, logger: app.logger, hasher: app.password)
            #expect(try await User.query(on: app.db).count() == 1)
        }
    }

    @Test func bootstrapSkippedWithoutVars() async throws {
        var config = AppConfig.testing
        config.adminUsername = nil
        config.adminPassword = nil
        try await withTestApp(config: config) { app in
            let count = try await User.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test func protectedRedirectsToLogin() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/") { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }
        }
    }

    @Test func htmxGetsHXRedirect() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/", headers: .htmx) { res async in
                #expect(res.headers.first(name: "HX-Redirect") == "/login")
            }
        }
    }

    @Test func loginSetsSecureCookie() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(LoginForm(username: "admin", password: "adminpass123"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
                let setCookie = res.headers.first(name: .setCookie) ?? ""
                #expect(setCookie.contains("watchswifty_session="))
                #expect(setCookie.contains("HttpOnly"))
                #expect(setCookie.contains("SameSite=Lax"))
                #expect(setCookie.contains("Max-Age=2592000"))
            })
        }
    }

    @Test func loggedInSeesHome() async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Weiterschauen"))
            }
        }
    }

    @Test func loginIsCaseInsensitiveOnUsername() async throws {
        try await withTestApp { app in
            _ = try await login(app, "ADMIN", password: "adminpass123")
        }
    }

    @Test func wrongPasswordAndUnknownUserSameMessage() async throws {
        try await withTestApp { app in
            for (user, pass) in [("admin", "wrong-password"), ("nobody", "whatever123")] {
                try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                    try req.content.encode(LoginForm(username: user, password: pass), as: .urlEncodedForm)
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Benutzername oder Passwort falsch."))
                    #expect(res.headers.first(name: .setCookie) == nil)
                })
            }
        }
    }

    @Test func logoutEndsSession() async throws {
        try await withTestApp { app in
            let headers = try await login(app, "admin", password: "adminpass123")
            try await app.testing().test(.POST, "/logout", headers: headers) { res async in
                #expect(res.status == .seeOther)
            }
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }
        }
    }

    @Test func originCheck() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/logout", headers: ["Origin": "http://evil.example", "Host": "localhost:8080"]) { res async in
                #expect(res.status == .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: ["Host": "localhost:8080"]) { res async in
                #expect(res.status == .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: .sameOrigin) { res async in
                #expect(res.status != .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: ["Host": "localhost:8080", "HX-Request": "true"]) { res async in
                #expect(res.status != .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: ["Host": "app:8080", "X-Forwarded-Host": "tv.lan:8080", "Origin": "http://tv.lan:8080"]) { res async in
                #expect(res.status != .forbidden)
            }
        }
    }
}

@Suite("OriginBehindProxy")
struct OriginBehindProxyTests {
    @Test func publicOriginConfig() throws {
        let c = try AppConfig.fromEnvironment(["PUBLIC_ORIGIN": "https://nas.lan:8443, http://tv.lan:8080/"])
        #expect(c.publicOrigins == ["https://nas.lan:8443", "http://tv.lan:8080"])
    }

    @Test func publicOriginAllowsMismatchedHost() async throws {
        var config = AppConfig.testing
        config.publicOrigins = ["https://nas.lan:8443"]
        try await withTestApp(config: config) { app in
            // nginx with `proxy_set_header Host $host;` drops the port.
            try await app.testing().test(.POST, "/logout", headers: ["Host": "nas.lan", "Origin": "https://nas.lan:8443"]) { res async in
                #expect(res.status != .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: ["Host": "nas.lan", "Origin": "https://evil.lan:8443"]) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func forwardedPortIsHonoured() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/logout", headers: [
                "Host": "app:8080", "X-Forwarded-Host": "nas.lan", "X-Forwarded-Port": "8443", "Origin": "https://nas.lan:8443",
            ]) { res async in
                #expect(res.status != .forbidden)
            }
            try await app.testing().test(.POST, "/logout", headers: [
                "Host": "app:8080", "X-Forwarded-Host": "nas.lan", "X-Forwarded-Port": "443", "X-Forwarded-Proto": "https",
                "Origin": "https://nas.lan",
            ]) { res async in
                #expect(res.status != .forbidden)
            }
        }
    }
}
