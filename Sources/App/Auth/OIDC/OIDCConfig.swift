import Foundation

/// The one OpenID Connect provider in effect, built from `OIDCSettings` (spec „Einstellungen“).
struct OIDCConfig: Sendable, Equatable {
    var issuer: String
    var clientID: String
    var clientSecret: String
    /// Where the provider sends the browser back; its origin is the canonical address of every OIDC flow.
    var redirectURL: URL
    /// Shown in buttons and messages (`OIDC_NAME`, default „SSO“).
    var displayName: String = "SSO"

    /// `scheme://host[:port]` of the redirect URL, normalized like the CSRF check's origins.
    var canonicalOrigin: String {
        var components = URLComponents()
        components.scheme = redirectURL.scheme
        components.host = redirectURL.host
        components.port = redirectURL.port
        return OriginCheckMiddleware.normalizeOrigin(components.string ?? "")
    }

    /// True when `stored` is this issuer, ignoring a trailing slash on either side.
    func matchesIssuer(_ stored: String?) -> Bool {
        guard let stored else { return false }
        return Self.trimmed(stored) == Self.trimmed(issuer)
    }

    static func trimmed(_ issuer: String) -> String {
        var value = issuer
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
