@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct AuthorizeForm: Content {
    var redirect_uri = "dev.patmei.watchswifty:/auth"
    var state = "xyz"
    var code_challenge: String
    var code_challenge_method = "S256"
    var device_name = "Patricks iPhone"
    var decision = "connect"
}

struct TokenRequestBody: Content {
    var code: String
    var codeVerifier: String
    var redirectUri = "dev.patmei.watchswifty:/auth"
}

struct TokenGrantBody: Codable {
    struct Device: Codable { let id: UUID; let name: String; let kind: String; let createdAt: Date; let expiresAt: Date }
    struct UserInfo: Codable { let username: String; let isAdmin: Bool }
    let token: String
    let expiresAt: Date
    let device: Device
    let user: UserInfo
}

struct LoginReturnForm: Content { var username: String; var password: String; var returnTo: String }

@Suite("APIAuthorize")
struct APIAuthorizeTests {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-verifier-1234567890"

    func authorizePath(challenge: String, redirect: String = "dev.patmei.watchswifty:/auth", device: String = "Patricks iPhone") -> String {
        var components = URLComponents(string: "/api/auth/authorize")!
        components.queryItems = [
            .init(name: "redirect_uri", value: redirect), .init(name: "state", value: "xyz"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "device_name", value: device),
        ]
        return components.string!
    }

    /// Logs in, confirms the consent form and returns the code from the app redirect.
    func connect(_ app: Application, headers: HTTPHeaders) async throws -> String {
        var code = ""
        try await app.testing().test(.POST, "/api/auth/authorize", headers: headers, beforeRequest: { req in
            try req.content.encode(AuthorizeForm(code_challenge: pkceChallenge(verifier)), as: .urlEncodedForm)
        }, afterResponse: { res async in
            #expect(res.status == .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            #expect(location.hasPrefix("dev.patmei.watchswifty:/auth?code="))
            #expect(location.contains("state=xyz"))
            code = URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value ?? ""
        })
        return code
    }

    func exchange(_ app: Application, code: String, verifier: String) async throws -> (HTTPStatus, TokenGrantBody?, String?) {
        var result: (HTTPStatus, TokenGrantBody?, String?) = (.internalServerError, nil, nil)
        try await app.testing().test(.POST, "/api/v1/auth/token", beforeRequest: { req in
            try req.content.encode(TokenRequestBody(code: code, codeVerifier: verifier), as: .json)
        }, afterResponse: { res async in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = (res.status, try? decoder.decode(TokenGrantBody.self, from: Data(res.body.readableBytesView)),
                      try? res.content.decode(APIErrorBody.self).code)
        })
        return result
    }

    @Test func fullBrowserFlow() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, authorizePath(challenge: pkceChallenge(verifier)), headers: web) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Patricks iPhone"))
                #expect(res.body.string.contains("Verbinden"))
            }
            let code = try await connect(app, headers: web)
            let (status, grant, _) = try await exchange(app, code: code, verifier: verifier)
            #expect(status == .ok)
            let token = try #require(grant?.token)
            #expect(grant?.device.name == "Patricks iPhone")
            #expect(grant?.device.kind == "device")
            #expect(abs((grant?.expiresAt.timeIntervalSinceNow ?? 0) - APITokenService.lifetime) < 60)
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func wrongVerifierIsInvalidGrant() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let code = try await connect(app, headers: try await login(app, "pat"))
            let (status, _, errorCode) = try await exchange(app, code: code, verifier: verifier + "x")
            #expect(status == .badRequest)
            #expect(errorCode == "invalidGrant")
        }
    }

    @Test func codeIsSingleUse() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let code = try await connect(app, headers: try await login(app, "pat"))
            #expect(try await exchange(app, code: code, verifier: verifier).0 == .ok)
            #expect(try await exchange(app, code: code, verifier: verifier).0 == .badRequest)
        }
    }

    @Test func codeExpiresAfter60Seconds() async throws {
        let store = AuthCodeStore()
        let now = Date()
        let code = await store.issue(userID: UUID(), challenge: pkceChallenge(verifier), redirectURI: "dev.patmei.watchswifty:/auth",
                                     deviceName: "X", now: now)
        await #expect(throws: APIError.invalidGrant) {
            try await store.redeem(code: code, verifier: verifier, redirectURI: "dev.patmei.watchswifty:/auth", now: now.addingTimeInterval(61))
        }
    }

    @Test func foreignRedirectURIRejected() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            // The old `watchswifty://auth` is gone: only the reverse-DNS scheme of the app counts.
            for redirect in ["https://evil.example/cb", "watchswifty://auth", "dev.patmei.watchswifty://auth"] {
                try await app.testing().test(.GET, authorizePath(challenge: pkceChallenge(verifier), redirect: redirect),
                                             headers: web) { res async in
                    #expect(res.status == .badRequest, "\(redirect)")
                    #expect(res.headers.first(name: .location) == nil)
                }
            }
        }
    }

    @Test func cancelReturnsAccessDenied() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            try await app.testing().test(.POST, "/api/auth/authorize", headers: web, beforeRequest: { req in
                var form = AuthorizeForm(code_challenge: pkceChallenge(verifier))
                form.decision = "cancel"
                try req.content.encode(form, as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "dev.patmei.watchswifty:/auth?error=access_denied&state=xyz")
            })
        }
    }

    @Test func loginReturnsToAuthorize() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let path = authorizePath(challenge: pkceChallenge(verifier))
            var loginLocation = ""
            try await app.testing().test(.GET, path) { res async in
                #expect(res.status == .seeOther)
                loginLocation = res.headers.first(name: .location) ?? ""
            }
            #expect(loginLocation.hasPrefix("/login?returnTo="))
            let returnTo = URLComponents(string: loginLocation)?.queryItems?.first { $0.name == "returnTo" }?.value
            #expect(returnTo == path)
            try await app.testing().test(.GET, loginLocation) { res async in
                #expect(res.body.string.contains(#"name="returnTo""#))
            }
            try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(LoginReturnForm(username: "pat", password: "password123", returnTo: path), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == path)
            })
        }
    }

    @Test func unsafeReturnToIgnored() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
                try req.content.encode(LoginReturnForm(username: "pat", password: "password123", returnTo: "https://evil.example"),
                                       as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.headers.first(name: .location) == "/")
            })
            #expect(!isSafeReturnTo("//evil.example/api/auth/authorize?x"))
            #expect(!isSafeReturnTo("/account"))
            #expect(isSafeReturnTo("/api/auth/authorize?state=1"))
        }
    }

    @Test func consentPageEscapesDeviceName() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, authorizePath(challenge: pkceChallenge(verifier), device: "<script>Ä</script>"),
                                         headers: web) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("„&lt;script&gt;Ä&lt;/script&gt;“"))           // visible text escaped, umlaut intact
                #expect(body.contains(#"value="<script>Ä</script>""#))               // inside a quoted attribute: inert
                #expect(!body.contains(#""><script>"#))                              // no attribute breakout
                #expect(body.components(separatedBy: "<script>Ä").count == 2)        // only that attribute value
            }
        }
    }

    @Test func revokeCurrentToken() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.DELETE, "/api/v1/auth/token", headers: .bearer(token)) { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/api/v1/me", headers: .bearer(token)) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func pkceChallengeMatchesRFC7636() {
        #expect(pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
