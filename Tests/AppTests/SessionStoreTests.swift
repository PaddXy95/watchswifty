@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Web sessions at rest (security audit F08/F18): only a hash of the cookie is stored, idle sessions end after
/// 30 days, and requests with unknown cookies leave no rows behind.
@Suite("SessionStore")
struct SessionStoreTests {
    func sessionCookie(_ headers: HTTPHeaders) throws -> String {
        try #require(cookieValue(headers, "watchswifty_session"))
    }

    func accountStatus(_ app: Application, cookie: String) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.testing().test(.GET, "/account", headers: ["Cookie": "watchswifty_session=\(cookie)"]) { res async in
            status = res.status
        }
        return status
    }

    @Test func databaseHoldsNoUsableSessionID() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let cookie = try sessionCookie(try await login(app, "pat"))
            #expect(try await accountStatus(app, cookie: cookie) == .ok)
            let stored = try await WebSession.query(on: app.db).all().map(\.keyHash)
                + (try await SessionRecord.query(on: app.db).all().map(\.key.string))
            #expect(!stored.isEmpty)
            #expect(!stored.contains(cookie))
            for value in stored {
                #expect(try await accountStatus(app, cookie: value) == .seeOther)
            }
        }
    }

    @Test func idleSessionExpiresAfterThirtyDays() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let cookie = try sessionCookie(try await login(app, "pat"))
            let row = try #require(try await WebSession.query(on: app.db).first())
            row.lastUsedAt = Date().addingTimeInterval(-31 * 86_400)
            try await row.save(on: app.db)
            #expect(try await accountStatus(app, cookie: cookie) == .seeOther)
            #expect(try await WebSession.query(on: app.db).count() == 0)
        }
    }

    @Test func activeSessionStaysValid() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let cookie = try sessionCookie(try await login(app, "pat"))
            let row = try #require(try await WebSession.query(on: app.db).first())
            row.lastUsedAt = Date().addingTimeInterval(-29 * 86_400)
            try await row.save(on: app.db)
            #expect(try await accountStatus(app, cookie: cookie) == .ok)
            let touched = try #require(try await WebSession.query(on: app.db).first())
            #expect(touched.lastUsedAt > Date().addingTimeInterval(-60))
        }
    }

    @Test func unknownCookiesLeaveNoRows() async throws {
        try await withTestApp { app in
            for index in 0..<3 {
                try await app.testing().test(.GET, "/healthz", headers: ["Cookie": "watchswifty_session=unknown-\(index)"]) { res async in
                    #expect(res.status == .ok)
                }
            }
            #expect(try await WebSession.query(on: app.db).count() == 0)
            #expect(try await SessionRecord.query(on: app.db).count() == 0)
        }
    }

    @Test func dailyPassPurgesIdleSessions() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            try await createUser(app, "ben")
            _ = try await login(app, "pat")
            _ = try await login(app, "ben")
            let rows = try await WebSession.query(on: app.db).all()
            #expect(rows.count == 2)
            rows[0].lastUsedAt = Date().addingTimeInterval(-31 * 86_400)
            try await rows[0].save(on: app.db)
            await runDailyPass(app)
            let left = try await WebSession.query(on: app.db).all()
            #expect(left.map(\.id) == [rows[1].id])
        }
    }

    @Test func logoutDeletesTheRow() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            #expect(try await WebSession.query(on: app.db).count() == 1)
            try await app.testing().test(.POST, "/logout", headers: headers) { res async in
                #expect(res.status == .seeOther)
            }
            #expect(try await WebSession.query(on: app.db).count() == 0)
        }
    }
}
