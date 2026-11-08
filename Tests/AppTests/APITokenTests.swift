@testable import App
import Crypto
import Fluent
import Foundation
import Testing
import VaporTesting

struct MeBody: Codable {
    struct TMDB: Codable { let state: String; let suffix: String? }
    let username: String
    let isAdmin: Bool
    let hasPassword: Bool
    let tmdbToken: TMDB
}

@Suite("APIToken")
struct APITokenTests {
    @Test func meRequiresToken() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api/v1/me") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(res.headers.first(name: .wwwAuthenticate) == "Bearer")
                #expect(try res.content.decode(APIErrorBody.self).code == "unauthorized")
            }
        }
    }

    @Test func meIgnoresSessionCookie() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, "/api/v1/me", headers: web) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func meWithToken() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                let me = try res.content.decode(MeBody.self)
                #expect(me.username == "pat")
                #expect(me.isAdmin == false)
                #expect(me.hasPassword)
                #expect(me.tmdbToken.state == "stored")
                #expect(me.tmdbToken.suffix == "…oken")
            }
        }
    }

    @Test func expiredTokenIs401TokenExpired() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user, now: Date().addingTimeInterval(-91 * 86_400))
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try res.content.decode(APIErrorBody.self).code == "tokenExpired")
            }
        }
    }

    @Test func tokenStoredAsHash() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            #expect(token.hasPrefix("ws_"))
            let stored = try #require(try await APIToken.query(on: app.db).first())
            let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(stored.tokenHash == hash)
            #expect(stored.tokenHash != token)
            #expect(stored.kind == APITokenKind.manual.rawValue)
            #expect(stored.expiresAt.timeIntervalSince(stored.createdAt) == APITokenService.lifetime)
        }
    }

    @Test func lastUsedUpdated() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            #expect(try await APIToken.query(on: app.db).first()?.lastUsedAt == nil)
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { _ async in }
            #expect(try await APIToken.query(on: app.db).first()?.lastUsedAt != nil)
        }
    }
}
