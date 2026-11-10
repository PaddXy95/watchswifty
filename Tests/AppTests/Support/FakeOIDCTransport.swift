@testable import App
import Foundation
import NIOConcurrencyHelpers

/// HTTP stand-in for `LiveOIDCProvider`: fixed answers per URL, records every request.
final class FakeOIDCTransport: OIDCTransport, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: String
        let fields: [String: String]
        let basicAuth: (user: String, password: String)?
    }

    enum Answer: Sendable {
        case response(status: UInt, body: Data)
        case unreachable
    }

    private struct State {
        var answers: [String: Answer] = [:]
        var requests: [Request] = []
    }

    private let state = NIOLockedValueBox(State())

    var requests: [Request] { state.withLockedValue { $0.requests } }

    func requests(to url: String) -> [Request] { requests.filter { $0.url == url } }

    func set(_ url: String, status: UInt = 200, json: String) {
        state.withLockedValue { $0.answers[url] = .response(status: status, body: Data(json.utf8)) }
    }

    func setUnreachable(_ url: String) {
        state.withLockedValue { $0.answers[url] = .unreachable }
    }

    func get(_ url: URL) async throws -> (status: UInt, body: Data) {
        try answer(Request(method: "GET", url: url.absoluteString, fields: [:], basicAuth: nil))
    }

    func postForm(_ url: URL, fields: [String: String], basicAuth: (user: String, password: String)?) async throws -> (status: UInt, body: Data) {
        try answer(Request(method: "POST", url: url.absoluteString, fields: fields, basicAuth: basicAuth))
    }

    private func answer(_ request: Request) throws -> (status: UInt, body: Data) {
        let answer = state.withLockedValue { state -> Answer? in
            state.requests.append(request)
            return state.answers[request.url]
        }
        switch answer {
        case .response(let status, let body): return (status, body)
        case .unreachable: throw OIDCError.unreachable
        case nil: return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
    }

    /// Discovery for `issuer` with the usual endpoints below `https://id.example.test`.
    static func discovery(issuer: String = OIDCTestKeys.issuer, authMethods: [String]? = nil, algs: [String] = ["ES256"]) -> String {
        var fields = [
            #""issuer":"\#(issuer)""#,
            #""authorization_endpoint":"https://id.example.test/authorize?tenant=home""#,
            #""token_endpoint":"https://id.example.test/token""#,
            #""jwks_uri":"https://id.example.test/jwks""#,
            #""id_token_signing_alg_values_supported":[\#(algs.map { "\"\($0)\"" }.joined(separator: ","))]"#,
        ]
        if let authMethods {
            fields.append(#""token_endpoint_auth_methods_supported":[\#(authMethods.map { "\"\($0)\"" }.joined(separator: ","))]"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static let discoveryURL = "https://id.example.test/.well-known/openid-configuration"
    static let tokenURL = "https://id.example.test/token"
    static let jwksURL = "https://id.example.test/jwks"
}

/// A settable clock for time-dependent caches.
final class TestClock: @unchecked Sendable {
    private let value: NIOLockedValueBox<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        value = NIOLockedValueBox(start)
    }

    var now: Date {
        get { value.withLockedValue { $0 } }
        set { value.withLockedValue { $0 = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
