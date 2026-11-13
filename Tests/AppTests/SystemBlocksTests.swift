@testable import App
import Elementary
import Foundation
import Testing
import VaporTesting

@Suite("SystemBlocks")
struct SystemBlocksTests {
    static let blocks = ["updates", "mail", "notifications", "oidc"]

    func admin(_ app: Application) async throws -> HTTPHeaders {
        try await login(app, "admin", password: "adminpass123")
    }

    func openBlocks(_ body: String) -> [String] {
        Self.blocks.filter { body.contains(#"<details class="system-block" id="block-\#($0)" open"#) }
    }

    func get(_ app: Application, _ path: String) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, path, headers: try await admin(app)) { res async in body = res.body.string }
        return body
    }

    func post(_ app: Application, _ path: String, form: [String: String] = [:]) async throws -> String {
        var body = ""
        try await app.testing().test(.POST, path, headers: try await admin(app), beforeRequest: { req in
            if !form.isEmpty { try req.content.encode(form, as: .urlEncodedForm) }
        }, afterResponse: { res async in body = res.body.string })
        return body
    }

    @Test func blocksStartClosed() async throws {
        try await withTestApp { app in
            let body = try await get(app, "/admin/system")
            for block in Self.blocks {
                #expect(body.contains(#"<details class="system-block" id="block-\#(block)""#))
            }
            #expect(openBlocks(body) == [])
            #expect(body.contains("Version &amp; Updates") || body.contains("Version & Updates"))
        }
    }

    @Test func openQueryOpensBlock() async throws {
        try await withTestApp { app in
            let updates = try await get(app, "/admin/system?open=updates")
            let unknown = try await get(app, "/admin/system?open=quatsch")
            #expect(openBlocks(updates) == ["updates"])
            #expect(openBlocks(unknown) == [])
        }
    }

    @Test func blockOfTheActionStaysOpen() async throws {
        try await withTestApp { app in
            let checked = try await post(app, "/admin/system/check-now")
            let mail = try await post(app, "/admin/system/mail/delete")
            let notifications = try await post(app, "/admin/system/notifications", form: ["dailyRunTime": "07:30", "webhookURL": ""])
            let oidc = try await post(app, "/admin/system/oidc/test")   // not configured → error, block open
            #expect(openBlocks(checked) == ["updates"])
            #expect(openBlocks(mail) == ["mail"])
            #expect(openBlocks(notifications) == ["notifications"])
            #expect(openBlocks(oidc) == ["oidc"])
        }
    }

    @Test func footerUpdateHintOpensUpdates() {
        let html = SiteFooter(updateVersion: "9.9.9").render()
        #expect(html.contains(#"href="/admin/system?open=updates""#))
    }
}
