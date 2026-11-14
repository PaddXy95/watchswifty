import Foundation
import Vapor

/// What a sign-in through the provider is for.
enum OIDCIntent: String, Codable, Sendable {
    /// Sign in (or create an account after confirmation).
    case login
    /// Link the signed-in account (Konto page, started by POST).
    case link
    /// Confirm the provider still lets this account in before an app is connected.
    case reauth
    /// Admin link token / `link-oidc`.
    case linkToken
    /// Accept an invitation through the provider.
    case invite
}

/// State between `/auth/oidc/start` and the callback, kept in a short-lived encrypted cookie instead of the session:
/// anonymous starts would otherwise leave a session row each (spec „Technische Entscheidungen“).
struct OIDCFlowCookie: Codable, Sendable {
    static let name = "watchswifty_oidc"
    static let lifetime: TimeInterval = 600

    var state: String
    var nonce: String
    var verifier: String
    var startedAt: Date
    var intent: OIDCIntent
    /// The signed-in user who started a `link`/`reauth` flow; the callback must run in that user's session.
    var userID: UUID?
    var returnTo: String?
    var linkToken: String?
    var inviteToken: String?
    /// Identity waiting for „Neues Konto anlegen“.
    var pending: OIDCIdentity?
    var pendingAt: Date?

    init(state: String, nonce: String, verifier: String, startedAt: Date, intent: OIDCIntent, returnTo: String? = nil,
         linkToken: String? = nil, inviteToken: String? = nil) {
        self.state = state
        self.nonce = nonce
        self.verifier = verifier
        self.startedAt = startedAt
        self.intent = intent
        self.returnTo = returnTo
        self.linkToken = linkToken
        self.inviteToken = inviteToken
    }

    func seal(_ cipher: TokenCipher) throws -> String {
        try cipher.seal(String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }

    /// The cookie's content; nil when missing, not sealed with this key, tampered with or older than ten minutes
    /// (counted from the start, or from parking the identity).
    static func open(_ value: String?, cipher: TokenCipher, now: Date) -> OIDCFlowCookie? {
        // `TokenCipher.open` passes unprefixed values through as legacy plaintext – never accept that here.
        guard let value, value.hasPrefix(TokenCipher.prefix), let json = cipher.open(value),
              let cookie = try? JSONDecoder().decode(OIDCFlowCookie.self, from: Data(json.utf8)) else { return nil }
        let reference = max(cookie.startedAt, cookie.pendingAt ?? cookie.startedAt)
        guard now.timeIntervalSince(reference) <= lifetime, reference <= now.addingTimeInterval(60) else { return nil }
        return cookie
    }

    func cookie(_ cipher: TokenCipher, secure: Bool) throws -> HTTPCookies.Value {
        HTTPCookies.Value(string: try seal(cipher), expires: nil, maxAge: Int(Self.lifetime), domain: nil, path: "/auth/oidc",
                          isSecure: secure, isHTTPOnly: true, sameSite: .lax)
    }

    static var expired: HTTPCookies.Value {
        HTTPCookies.Value(string: "", expires: Date(timeIntervalSince1970: 0), maxAge: 0, domain: nil, path: "/auth/oidc",
                          isSecure: false, isHTTPOnly: true, sameSite: .lax)
    }
}

/// Makes a flow cookie single-use: the cookie itself is stateless, so used `state` values are remembered for its
/// lifetime (in memory; enough for one process).
actor OIDCUsedStates {
    private var seen: [String: Date] = [:]

    /// True the first time a state is presented within ten minutes.
    func consume(_ state: String, now: Date = .now) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) <= OIDCFlowCookie.lifetime }
        guard seen[state] == nil else { return false }
        seen[state] = now
        return true
    }
}
