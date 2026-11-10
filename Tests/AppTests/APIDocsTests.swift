@testable import App
import Foundation
import Testing
import VaporTesting

@Suite("APIDocs")
struct APIDocsTests {
    @Test func docsPageWithoutLogin() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api") { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("/api-docs/swagger-ui-bundle.js"))
                #expect(body.contains("/api-docs/swagger-ui.css"))
                #expect(body.contains("/api-docs/init.js"))
                #expect(body.contains(#"id="swagger-ui""#))
            }
            try await app.testing().test(.GET, "/api-docs/init.js") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#"url: "/api/openapi.yaml""#))
                #expect(res.body.string.contains("persistAuthorization: false"))   // bearer token never in localStorage
                #expect(res.body.string.contains(#"localStorage.removeItem("authorized")"#))
            }
        }
    }

    @Test func specIsServed() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api/openapi.yaml") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("openapi: 3.1.0"))
                #expect(res.body.string.contains("bearerAuth"))
            }
        }
    }

    @Test func specMatchesSource() async throws {
        let source = try String(contentsOfFile: "Sources/WatchSwiftyAPI/openapi.yaml", encoding: .utf8)
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api/openapi.yaml") { res async in
                #expect(res.body.string == source)
            }
        }
    }
}
