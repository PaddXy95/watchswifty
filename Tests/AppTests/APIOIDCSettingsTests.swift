@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

private struct OIDCSettingsBody: Decodable {
    let configured: Bool
    let unreadable: Bool
    let hasClientSecret: Bool
    let passwordLogin: Bool
    let passwordLoginForced: Bool
    let passwordLoginStored: Bool?
    let displayName: String?
    let issuer: String?
    let clientId: String?
    let baseUrl: String?
    let redirectUrl: String?
    let checkError: String?
}
private struct OIDCUpdateBody: Content { var displayName: String?; var issuer: String; var clientId: String; var clientSecret: String?; var baseUrl: String }
private struct OIDCCheckBody: Decodable { let issuer: String; let keyCount: Int }
private struct PasswordLoginBody: Content { var enabled: Bool }

@Suite("APIOIDCSettings")
struct APIOIDCSettingsTests {
    private let update = OIDCUpdateBody(displayName: "Authentik", issuer: "https://id.example.test", clientId: "watchswifty",
                                        clientSecret: "very-secret-value", baseUrl: "http://localhost:8080")

    private func admin(_ app: Application) async throws -> (User, String) {
        let chef = try await createUser(app, "chef", isAdmin: true)
        return (chef, try await apiToken(app, chef))
    }

    @Test func getWithoutSettings() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.GET, "/api/v1/admin/oidc", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(OIDCSettingsBody.self)
                #expect(!body.configured)
                #expect(body.passwordLogin)
                #expect(!body.hasClientSecret)
            }
        }
    }

    @Test func putSavesWithoutReturningTheSecret() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.PUT, "/api/v1/admin/oidc", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(update, as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("very-secret-value"))
                let body = try res.content.decode(OIDCSettingsBody.self)
                #expect(body.configured)
                #expect(body.hasClientSecret)
                #expect(body.displayName == "Authentik")
                #expect(body.redirectUrl == "http://localhost:8080/auth/oidc/callback")
                #expect(body.checkError == nil)
            })
            #expect(app.loginSettings.current.oidc?.issuer == "https://id.example.test")
        }
    }

    @Test func putReportsFailedCheck() async throws {
        let fake = FakeOIDCProvider()
        fake.startError = .unreachable
        try await withTestApp(oidc: fake) { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.PUT, "/api/v1/admin/oidc", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(update, as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(OIDCSettingsBody.self).checkError == "Authentik ist nicht erreichbar.")
            })
        }
    }

    @Test func putValidates() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            var bad = update
            bad.clientSecret = nil
            try await app.testing().test(.PUT, "/api/v1/admin/oidc", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(bad, as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == OIDCSettingsService.secretMissingMessage)
            })
        }
    }

    @Test func testEndpoint() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.POST, "/api/v1/admin/oidc/test", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
            _ = try await app.oidcSettings.save(OIDCSettingsInput(displayName: nil, issuer: "https://id.example.test",
                                                                 clientID: "w", clientSecret: "s", baseURL: "http://localhost:8080"))
            try await app.testing().test(.POST, "/api/v1/admin/oidc/test", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(OIDCCheckBody.self)
                #expect(body.issuer == "https://id.example.test")
                #expect(body.keyCount == 1)
            }
        }
    }

    @Test func passwordLoginGuardsAndDelete() async throws {
        try await withTestApp { app in
            let (chef, token) = try await admin(app)
            _ = try await app.oidcSettings.save(OIDCSettingsInput(displayName: nil, issuer: "https://id.example.test",
                                                                 clientID: "w", clientSecret: "s", baseURL: "http://localhost:8080"))
            try await app.testing().test(.PUT, "/api/v1/admin/oidc/password-login", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(PasswordLoginBody(enabled: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
            })
            try await linkOIDC(app, chef)
            try await app.testing().test(.PUT, "/api/v1/admin/oidc/password-login", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(PasswordLoginBody(enabled: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(OIDCSettingsBody.self).passwordLogin == false)
            })
            try await app.testing().test(.DELETE, "/api/v1/admin/oidc", headers: .bearer(token)) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
            try await app.testing().test(.PUT, "/api/v1/admin/oidc/password-login", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(PasswordLoginBody(enabled: true), as: .json)
            })
            try await app.testing().test(.DELETE, "/api/v1/admin/oidc", headers: .bearer(token)) { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(app.loginSettings.current.oidc == nil)
        }
    }

    @Test func nonAdminForbidden() async throws {
        try await withTestApp { app in
            let token = try await apiToken(app, try await createUser(app, "anna"))
            try await app.testing().test(.GET, "/api/v1/admin/oidc", headers: .bearer(token)) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func forcedReportsStoredValue() async throws {
        var config = AppConfig.testingOIDC
        config.passwordLogin = false
        config.passwordLoginForced = true
        try await withTestApp(config: config) { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.GET, "/api/v1/admin/oidc", headers: .bearer(token)) { res async throws in
                let body = try res.content.decode(OIDCSettingsBody.self)
                #expect(body.passwordLogin)
                #expect(body.passwordLoginForced)
                #expect(body.passwordLoginStored == false)
            }
        }
    }
}
