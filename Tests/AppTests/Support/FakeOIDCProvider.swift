@testable import App
import Foundation
import NIOConcurrencyHelpers
import VaporTesting

/// OIDC provider stand-in: returns `identity` (or throws `error`) and remembers what the app sent.
final class FakeOIDCProvider: OIDCProvider, @unchecked Sendable {
    struct Exchange: Sendable {
        let code: String
        let codeVerifier: String
        let nonce: String
    }

    private struct State {
        var identity: OIDCIdentity? = oidcIdentity()
        var error: OIDCError?
        var startError: OIDCError?
        var issuer = OIDCTestKeys.issuer
        var lastState: String?
        var lastNonce: String?
        var lastChallenge: String?
        var exchanges: [Exchange] = []
    }

    private let state = NIOLockedValueBox(State())

    var identity: OIDCIdentity? {
        get { state.withLockedValue { $0.identity } }
        set { state.withLockedValue { $0.identity = newValue } }
    }
    /// Thrown by `exchange`.
    var error: OIDCError? {
        get { state.withLockedValue { $0.error } }
        set { state.withLockedValue { $0.error = newValue } }
    }
    /// Thrown by `authorizationURL`.
    var startError: OIDCError? {
        get { state.withLockedValue { $0.startError } }
        set { state.withLockedValue { $0.startError = newValue } }
    }
    var issuer: String {
        get { state.withLockedValue { $0.issuer } }
        set { state.withLockedValue { $0.issuer = newValue } }
    }
    var lastState: String? { state.withLockedValue { $0.lastState } }
    var lastNonce: String? { state.withLockedValue { $0.lastNonce } }
    var lastChallenge: String? { state.withLockedValue { $0.lastChallenge } }
    var exchanges: [Exchange] { state.withLockedValue { $0.exchanges } }

    func authorizationURL(state: String, nonce: String, codeChallenge: String) async throws -> URL {
        if let error = startError { throw error }
        self.state.withLockedValue {
            $0.lastState = state
            $0.lastNonce = nonce
            $0.lastChallenge = codeChallenge
        }
        return URL(string: "https://id.example.test/authorize?state=\(state)")!
    }

    func exchange(code: String, codeVerifier: String, nonce: String) async throws -> OIDCIdentity {
        let (identity, error, expectedNonce, challenge) = state.withLockedValue { s in
            s.exchanges.append(Exchange(code: code, codeVerifier: codeVerifier, nonce: nonce))
            return (s.identity, s.error, s.lastNonce, s.lastChallenge)
        }
        if let error { throw error }
        // What the real provider checks: the nonce and PKCE verifier belong to this login.
        guard nonce == expectedNonce, pkceChallenge(codeVerifier) == challenge, let identity else {
            throw OIDCError.failed(logReason: "fake: nonce/verifier mismatch")
        }
        return identity
    }

    func discoveredIssuer() async throws -> String { issuer }
}

/// Identity from the test provider (`https://id.example.test`).
func oidcIdentity(_ subject: String = "sub-1", username: String? = "anna", email: String? = "anna@example.org",
                  name: String? = "Anna Beispiel", issuer: String = OIDCTestKeys.issuer) -> OIDCIdentity {
    OIDCIdentity(issuer: issuer, subject: subject, preferredUsername: username, email: email, name: name)
}
