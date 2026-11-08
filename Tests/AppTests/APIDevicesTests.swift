@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct DeviceNameForm: Content { var name: String }
struct DeviceBody: Codable { let id: UUID; let name: String; let kind: String }

@Suite("APIDevices")
struct APIDevicesTests {
    func newToken(in body: String) -> String? {
        body.firstMatch(of: /<code class="new-token">(ws_[A-Za-z0-9_-]+)<\/code>/).map { String($0.1) }
    }

    @Test func accountListsDevicesAndRevokes() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let issued = try await APITokenService(db: app.db).issue(userID: user.requireID(), name: "Patricks iPhone", kind: .device)
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, "/account", headers: web) { res async in
                let body = res.body.string
                #expect(body.contains("Geräte"))
                #expect(body.contains("Patricks iPhone"))
                #expect(body.contains("Gerät ·"))
            }
            try await app.testing().test(.POST, "/account/devices/\(try issued.record.requireID())/revoke", headers: web) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Gerät abgemeldet."))
            }
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(issued.token)) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func manualTokenShownOnceAndWorks() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            var token: String?
            try await app.testing().test(.POST, "/account/devices", headers: web, beforeRequest: { req in
                try req.content.encode(DeviceNameForm(name: "Skript"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Neues Token (wird nur jetzt angezeigt)"))
                #expect(res.body.string.contains("manuell erstellt"))
                token = newToken(in: res.body.string)
            })
            let plain = try #require(token)
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(plain)) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func tokenAppearsOnlyOnce() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            var token = ""
            try await app.testing().test(.POST, "/account/devices", headers: web, beforeRequest: { req in
                try req.content.encode(DeviceNameForm(name: "Skript"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                token = newToken(in: res.body.string) ?? ""
            })
            #expect(!token.isEmpty)
            let hash = APITokenService.hash(token)
            try await app.testing().test(.GET, "/account", headers: web) { res async in
                #expect(!res.body.string.contains(token))
                #expect(!res.body.string.contains(hash))
            }
            try await app.testing().test(.GET, "/api/v1/me/devices", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains(token))
                #expect(!res.body.string.contains(hash))
                let devices = try res.content.decode([DeviceBody].self)
                #expect(devices.map(\.name) == ["Skript"])
                #expect(devices.first?.kind == "manual")
            }
        }
    }

    @Test func revokeOtherUsersDevice404() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let other = try await createUser(app, "other")
            let mine = try await apiToken(app, pat)
            let theirs = try await APITokenService(db: app.db).issue(userID: other.requireID(), name: "X", kind: .device)
            try await app.testing().test(.DELETE, "/api/v1/me/devices/\(try theirs.record.requireID())", headers: .bearer(mine)) { res async throws in
                #expect(res.status == .notFound)
                #expect(try res.content.decode(APIErrorBody.self).code == "notFound")
            }
            let web = try await login(app, "pat")
            try await app.testing().test(.POST, "/account/devices/\(try theirs.record.requireID())/revoke", headers: web) { res async in
                #expect(res.status == .notFound)
            }
            #expect(try await APIToken.find(theirs.record.requireID(), on: app.db) != nil)
        }
    }

    @Test func revokeOwnDeviceViaAPI() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let mine = try await apiToken(app, pat)
            let phone = try await APITokenService(db: app.db).issue(userID: pat.requireID(), name: "iPhone", kind: .device)
            try await app.testing().test(.DELETE, "/api/v1/me/devices/\(try phone.record.requireID())", headers: .bearer(mine)) { res async in
                #expect(res.status == .noContent)
            }
            #expect(try await APIToken.find(phone.record.requireID(), on: app.db) == nil)
        }
    }

    @Test func expiredTokensDeleted() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            _ = try await apiToken(app, user, now: Date().addingTimeInterval(-91 * 86_400))
            _ = try await apiToken(app, user)
            #expect(try await APITokenService(db: app.db).deleteExpired() == 1)
            #expect(try await APIToken.query(on: app.db).count() == 1)
        }
    }
}
