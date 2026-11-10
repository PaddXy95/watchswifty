@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// What a browser ends up with after an OIDC round trip.
struct OIDCFlowResult {
    let status: HTTPStatus
    let location: String?
    let body: String
    /// The request headers plus every cookie the responses set (session, flow cookie) – for the next request.
    let headers: HTTPHeaders
}

extension HTTPHeaders {
    /// Adds or replaces one cookie in the `Cookie` header; an empty value removes it.
    func settingCookie(_ name: String, _ value: String?) -> HTTPHeaders {
        var cookies = (first(name: .cookie) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(name + "=") }
        if let value, !value.isEmpty { cookies.append("\(name)=\(value)") }
        var headers = self
        headers.remove(name: .cookie)
        if !cookies.isEmpty { headers.add(name: .cookie, value: cookies.joined(separator: "; ")) }
        return headers
    }

    /// Applies the `Set-Cookie` headers of a response.
    func applying(_ response: HTTPHeaders) -> HTTPHeaders {
        var headers = self
        for name in [OIDCFlowCookie.name, "watchswifty_session"] {
            if let cookie = response.setCookie?[name] {
                headers = headers.settingCookie(name, cookie.string)
            }
        }
        return headers
    }
}

/// Sends a GET and returns status, location, body and the headers with the response's cookies applied.
func browserGet(_ app: Application, _ path: String, headers: HTTPHeaders) async throws -> OIDCFlowResult {
    var result: OIDCFlowResult?
    try await app.testing().test(.GET, path, headers: headers) { res async in
        result = OIDCFlowResult(status: res.status, location: res.headers.first(name: .location), body: res.body.string,
                                headers: headers.applying(res.headers))
    }
    return try #require(result)
}

/// Runs `/auth/oidc/start` and, when it goes to the provider, the callback with the fake's state.
func oidcFlow(_ app: Application, _ fake: FakeOIDCProvider, start: String = "/auth/oidc/start",
              headers: HTTPHeaders = .sameOrigin) async throws -> OIDCFlowResult {
    let started = try await browserGet(app, start, headers: headers)
    guard started.status == .seeOther, started.location?.hasPrefix("https://id.example.test/authorize") == true,
          let state = fake.lastState else { return started }
    return try await browserGet(app, "/auth/oidc/callback?code=test-code&state=\(state)", headers: started.headers)
}

/// Links `user` with the test provider's identity `subject`.
func linkOIDC(_ app: Application, _ user: User, subject: String = "sub-1", issuer: String = OIDCTestKeys.issuer) async throws {
    user.oidcIssuer = issuer
    user.oidcSubject = subject
    try await user.save(on: app.db)
}
