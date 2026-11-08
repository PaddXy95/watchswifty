@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct PasswordChangeBody: Content { var currentPassword: String; var newPassword: String }
struct TMDBTokenBody: Content { var token: String }
struct FollowedBody: Codable { let tmdbId: Int; let name: String; let nextEpisode: NextEpisodeBody? }

@Suite("APIAccount")
struct APIAccountTests {
    @Test func changePasswordNeedsCurrent() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.PUT, "/api/v1/me/password", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(PasswordChangeBody(currentPassword: "falsch", newPassword: "neuespasswort"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == AccountValidation.wrongCurrentPasswordMessage)
            })
            try await app.testing().test(.PUT, "/api/v1/me/password", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(PasswordChangeBody(currentPassword: "password123", newPassword: "neuespasswort"), as: .json)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            _ = try await login(app, "pat", password: "neuespasswort")
        }
    }

    @Test func tmdbTokenValidatedAndEncrypted() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            let token = try await apiToken(app, user)
            try await app.testing().test(.PUT, "/api/v1/me/tmdb-token", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(TMDBTokenBody(token: "  eyJneuer-token-wxyz  "), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let me = try res.content.decode(MeBody.self)
                #expect(me.tmdbToken.state == "stored")
                #expect(me.tmdbToken.suffix == "…wxyz")
            })
            #expect(tmdb.calls.contains("validate"))
            let stored = try await User.find(user.requireID(), on: app.db)?.tmdbToken
            #expect(stored?.hasPrefix("enc:v1:") == true)
            try await app.testing().test(.DELETE, "/api/v1/me/tmdb-token", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(MeBody.self).tmdbToken.state == "none")
            }
        }
    }

    @Test func rejectedTMDBTokenNotStored() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .unauthorized
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            let token = try await apiToken(app, user)
            try await app.testing().test(.PUT, "/api/v1/me/tmdb-token", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(TMDBTokenBody(token: "falsch"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == "TMDB hat den Token abgelehnt.")
            })
            #expect(try await User.find(user.requireID(), on: app.db)?.tmdbToken == nil)
        }
    }

    @Test func followedList() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, name: "Beobachtet", seasons: [1: 2], airDates: ["1x2": "2026-11-12"])
            try await WatchService(db: app.db, today: { "2026-11-07" }).setFollowed(userID: user.requireID(), titleID: show.requireID(), followed: true)
            try await app.testing().test(.GET, "/api/v1/me/followed", headers: .bearer(token)) { res async throws in
                let list = try res.content.decode([FollowedBody].self)
                #expect(list.map(\.name) == ["Beobachtet"])
                #expect(list.first?.nextEpisode?.number == 2)
            }
        }
    }
}
