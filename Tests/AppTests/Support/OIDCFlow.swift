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

/// Sends a form POST (same origin unless `headers` say otherwise) and applies the response's cookies.
func browserPost(_ app: Application, _ path: String, form: [String: String], headers: HTTPHeaders) async throws -> OIDCFlowResult {
    var result: OIDCFlowResult?
    try await app.testing().test(.POST, path, headers: headers, beforeRequest: { req in
        try req.content.encode(form, as: .urlEncodedForm)
    }, afterResponse: { res async in
        result = OIDCFlowResult(status: res.status, location: res.headers.first(name: .location), body: res.body.string,
                                headers: headers.applying(res.headers))
    })
    return try #require(result)
}

/// The value of one cookie in a request's `Cookie` header.
func cookieValue(_ headers: HTTPHeaders, _ name: String) -> String? {
    (headers.first(name: .cookie) ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
}

/// Runs a link-token flow, shows the confirmation page and confirms it with „Verknüpfen“. Returns the first response
/// that is not the expected next step (an error page), else the confirmation's response.
func confirmLinkToken(_ app: Application, _ fake: FakeOIDCProvider, token: String,
                      headers: HTTPHeaders = .sameOrigin) async throws -> OIDCFlowResult {
    let flow = try await oidcFlow(app, fake, start: "/auth/oidc/start?link=\(token)", headers: headers)
    guard flow.location == "/auth/oidc/link" else { return flow }
    let page = try await browserGet(app, "/auth/oidc/link", headers: flow.headers)
    guard page.status == .ok else { return page }
    return try await browserPost(app, "/auth/oidc/link", form: [:], headers: page.headers)
}

/// Runs the flow for `fake.identity` up to the „Neues Konto anlegen“ page and returns the page with the parked cookie.
func newAccountPage(_ app: Application, _ fake: FakeOIDCProvider, start: String = "/auth/oidc/start") async throws -> OIDCFlowResult {
    let flow = try await oidcFlow(app, fake, start: start)
    #expect(flow.location == "/auth/oidc/new-account")
    return try await browserGet(app, "/auth/oidc/new-account", headers: flow.headers)
}
