@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AccountBlocks")
struct AccountBlocksTests {
    static let blocks = ["tmdb", "followed", "notifications", "devices", "email", "password"]

    func openBlocks(_ body: String) -> [String] {
        Self.blocks.filter { body.contains(#"<details class="fold-block" id="block-\#($0)" open"#) }
    }

    /// "pat" with a readable TMDB token (so the token block has no reason to be open).
    func withPat(_ body: (Application, HTTPHeaders) async throws -> Void) async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            pat.tmdbToken = try app.tokenCipher.seal("eyJ-test-token-1234")
            try await pat.save(on: app.db)
            try await body(app, try await login(app, "pat"))
        }
    }

    func get(_ app: Application, _ headers: HTTPHeaders, _ path: String) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, path, headers: headers) { res async in body = res.body.string }
        return body
    }

    func post(_ app: Application, _ headers: HTTPHeaders, _ path: String, _ form: [String: String] = [:]) async throws -> String {
        var body = ""
        try await app.testing().test(.POST, path, headers: headers, beforeRequest: { req in
            if !form.isEmpty { try req.content.encode(form, as: .urlEncodedForm) }
        }, afterResponse: { res async in body = res.body.string })
        return body
    }

    @Test func blocksStartClosed() async throws {
        try await withPat { app, headers in
            let body = try await get(app, headers, "/account")
            for block in Self.blocks {
                #expect(body.contains(#"<details class="fold-block" id="block-\#(block)""#))
            }
            #expect(openBlocks(body) == [])
        }
    }

    @Test func tokenBlockOpenWithoutToken() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat", tmdbToken: nil)
            let body = try await get(app, try await login(app, "pat"), "/account")
            #expect(openBlocks(body) == ["tmdb"])
        }
    }

    @Test func openQueryOpensBlock() async throws {
        try await withPat { app, headers in
            let devices = try await get(app, headers, "/account?open=devices")
            let unknown = try await get(app, headers, "/account?open=quatsch")
            #expect(openBlocks(devices) == ["devices"])
            #expect(openBlocks(unknown) == [])
        }
    }

    @Test func blockOfTheActionStaysOpen() async throws {
        try await withPat { app, headers in
            let token = try await post(app, headers, "/account/devices", ["name": "Skript"])
            #expect(openBlocks(token) == ["devices"])
            #expect(token.contains("Neues Token (wird nur jetzt angezeigt)"))
            let prefs = try await post(app, headers, "/account/notifications", ["channel": "mail"])
            #expect(openBlocks(prefs) == ["notifications"])
            let email = try await post(app, headers, "/account/email", ["email": "pat@example.org", "currentPassword": "falsch"])
            #expect(openBlocks(email) == ["email"])
            let password = try await post(app, headers, "/account/password", ["currentPassword": "falsch", "newPassword": "neuespasswort"])
            #expect(openBlocks(password) == ["password"])
            let removed = try await post(app, headers, "/account/tmdb-token/remove")
            #expect(openBlocks(removed) == ["tmdb"])
        }
    }
}
