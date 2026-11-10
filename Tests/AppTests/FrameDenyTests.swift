@testable import App
import Testing
import VaporTesting

@Suite("FrameDeny")
struct FrameDenyTests {
    func expectNoFraming(_ res: TestingHTTPResponse, _ path: String) {
        #expect(res.headers.first(name: "X-Frame-Options") == "DENY", "\(path)")
        #expect(res.headers.first(name: "Content-Security-Policy") == "frame-ancestors 'none'", "\(path)")
    }

    @Test func everyResponseForbidsFraming() async throws {
        try await withTestApp { app in
            for path in ["/login", "/nope", "/favicon.svg", "/api", "/api/v1/me"] {
                try await app.testing().test(.GET, path) { res async in
                    expectNoFraming(res, path)
                }
            }
        }
    }

    @Test func consentPageForbidsFraming() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            let flow = APIAuthorizeTests()
            let path = flow.authorizePath(challenge: pkceChallenge(flow.verifier))
            try await app.testing().test(.GET, path, headers: web) { res async in
                #expect(res.status == .ok)
                expectNoFraming(res, path)
            }
        }
    }
}
