@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct SystemBody: Codable {
    struct Version: Codable { let version: String }
    struct Update: Codable { let enabled: Bool; let latestVersion: String?; let latestUrl: String?; let updateAvailable: Bool? }
    let version: Version; let updateCheck: Update
}
struct EnabledBody: Content { var enabled: Bool }

@Suite("APISystem")
struct APISystemTests {
    @Test func systemAdminOnly() async throws {
        try await withTestApp(config: UpdateCheckTests.releaseConfig) { app in
            let pat = try await createUser(app, "pat")
            let token = try await apiToken(app, pat)
            try await app.testing().test(.GET, "/api/v1/admin/system", headers: .bearer(token)) { res async in
                #expect(res.status == .forbidden)
            }
            let chef = try await createUser(app, "chef", isAdmin: true)
            let adminToken = try await apiToken(app, chef)
            try await app.testing().test(.GET, "/api/v1/admin/system", headers: .bearer(adminToken)) { res async throws in
                let system = try res.content.decode(SystemBody.self)
                #expect(system.version.version == "0.1.0")
                #expect(system.updateCheck.enabled == false)
                #expect(system.updateCheck.latestVersion == nil)
            }
        }
    }

    @Test func enablingChecksOnce() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(config: UpdateCheckTests.releaseConfig, releases: fetcher) { app in
            let chef = try await createUser(app, "chef", isAdmin: true)
            let token = try await apiToken(app, chef)
            for _ in 1...2 {
                try await app.testing().test(.PUT, "/api/v1/admin/system/update-check", headers: .bearer(token), beforeRequest: { req in
                    try req.content.encode(EnabledBody(enabled: true), as: .json)
                }, afterResponse: { res async throws in
                    #expect(try res.content.decode(SystemBody.self).updateCheck.enabled == true)
                })
            }
            #expect(fetcher.calls == 1)
        }
    }

    @Test func checkNowReportsUpdate() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(config: UpdateCheckTests.releaseConfig, releases: fetcher) { app in
            let chef = try await createUser(app, "chef", isAdmin: true)
            let token = try await apiToken(app, chef)
            try await app.testing().test(.POST, "/api/v1/admin/system/check-now", headers: .bearer(token)) { res async throws in
                let system = try res.content.decode(SystemBody.self)
                #expect(system.updateCheck.latestVersion == "0.1.3")
                #expect(system.updateCheck.updateAvailable == true)
                #expect(system.updateCheck.latestUrl == "https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3")
            }
        }
    }
}
