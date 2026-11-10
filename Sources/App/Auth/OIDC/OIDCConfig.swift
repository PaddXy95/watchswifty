import Foundation

/// The one OpenID Connect provider (spec `2026-11-07-oidc-login-design.md`, „Konfiguration“).
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

    /// `nil` when no OIDC variable is set. Throws `ConfigError` for a partial setup, a missing redirect address or an
    /// unreadable secret file.
    static func fromEnvironment(_ env: [String: String], publicOrigins: [String]) throws -> OIDCConfig? {
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        let issuer = value("OIDC_ISSUER")
        let clientID = value("OIDC_CLIENT_ID")
        let secretFile = value("OIDC_CLIENT_SECRET_FILE")
        var secret = value("OIDC_CLIENT_SECRET")
        if secret == nil, let secretFile {
            guard let data = FileManager.default.contents(atPath: secretFile),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw ConfigError.invalid("OIDC_CLIENT_SECRET_FILE ist nicht lesbar oder leer: \(secretFile)")
            }
            secret = text
        }
        if issuer == nil, clientID == nil, secret == nil, secretFile == nil { return nil }
        guard let issuer, let clientID, let secret else {
            throw ConfigError.invalid(
                "OIDC unvollständig: OIDC_ISSUER, OIDC_CLIENT_ID und OIDC_CLIENT_SECRET (oder _FILE) gehören zusammen.")
        }
        let redirect: String
        if let explicit = value("OIDC_REDIRECT_URL") {
            redirect = explicit
        } else if let origin = publicOrigins.first {
            redirect = origin + "/auth/oidc/callback"
        } else {
            throw ConfigError.invalid("OIDC braucht OIDC_REDIRECT_URL oder PUBLIC_ORIGIN.")
        }
        guard let url = URL(string: redirect), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ConfigError.invalid("OIDC_REDIRECT_URL ist keine gültige http(s)-Adresse: \(redirect)")
        }
        return OIDCConfig(issuer: issuer, clientID: clientID, clientSecret: secret, redirectURL: url,
                          displayName: value("OIDC_NAME") ?? "SSO")
    }
}
