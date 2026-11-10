import Foundation
import Logging

/// OIDC client over `jwt-kit` (spec „Konfiguration“): discovery cached for 24 hours and dropped when an endpoint
/// disappears, JWKS loaded on first use and reloaded at most once a minute for an unknown `kid`.
actor LiveOIDCProvider: OIDCProvider {
    static let discoveryLifetime: TimeInterval = 86_400
    static let keyReloadInterval: TimeInterval = 60

    private let config: OIDCConfig
    private let transport: any OIDCTransport
    private let logger: Logger
    private let now: @Sendable () -> Date
    private let validator = OIDCTokenValidator()

    private var cachedDiscovery: (value: OIDCDiscovery, loadedAt: Date)?
    private var keySet: OIDCKeySet?
    private var keysLoadedAt: Date?

    init(config: OIDCConfig, transport: any OIDCTransport, logger: Logger, now: @escaping @Sendable () -> Date = { .now }) {
        self.config = config
        self.transport = transport
        self.logger = logger
        self.now = now
    }

    func authorizationURL(state: String, nonce: String, codeChallenge: String) async throws -> URL {
        let discovery = try await discovery()
        guard var components = URLComponents(string: discovery.authorizationEndpoint) else {
            throw OIDCError.misconfigured(logReason: "authorization_endpoint der Discovery ist keine URL")
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURL.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // `+` is legal in a query but means a space to form decoders; encode it like the rest.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw OIDCError.misconfigured(logReason: "Autorisierungs-URL ungültig") }
        return url
    }

    func exchange(code: String, codeVerifier: String, nonce: String) async throws -> OIDCIdentity {
        let discovery = try await discovery()
        let idToken = try await tokenRequest(discovery, code: code, codeVerifier: codeVerifier)
        do {
            return try await validator.validate(idToken, keys: try await keys(discovery), issuer: discovery.issuer,
                                                clientID: config.clientID, nonce: nonce, now: now())
        } catch OIDCError.unknownKey(let kid) {
            guard let loadedAt = keysLoadedAt, now().timeIntervalSince(loadedAt) > Self.keyReloadInterval else {
                throw OIDCError.unknownKey(kid: kid)
            }
            keySet = nil
            return try await validator.validate(idToken, keys: try await keys(discovery), issuer: discovery.issuer,
                                                clientID: config.clientID, nonce: nonce, now: now())
        }
    }

    func discoveredIssuer() async throws -> String {
        try await discovery().issuer
    }

    func check() async throws -> OIDCCheck {
        dropDiscovery()
        let discovery = try await discovery()
        let keys = try await keys(discovery)
        return OIDCCheck(issuer: discovery.issuer, keyCount: keys.keyCount)
    }

    // MARK: - Discovery and keys

    private func discovery() async throws -> OIDCDiscovery {
        if let cached = cachedDiscovery, now().timeIntervalSince(cached.loadedAt) <= Self.discoveryLifetime {
            return cached.value
        }
        guard let url = URL(string: OIDCConfig.trimmed(config.issuer) + "/.well-known/openid-configuration") else {
            throw OIDCError.misconfigured(logReason: "OIDC_ISSUER ist keine URL")
        }
        let (status, body) = try await transport.get(url)
        guard status == 200 else {
            if status >= 500 { throw OIDCError.unreachable }
            throw OIDCError.misconfigured(logReason: "Discovery antwortete mit HTTP \(status)")
        }
        let discovery: OIDCDiscovery
        do {
            discovery = try JSONDecoder().decode(OIDCDiscovery.self, from: body)
        } catch {
            throw OIDCError.misconfigured(logReason: "Discovery unvollständig (authorization_endpoint, token_endpoint, jwks_uri)")
        }
        guard OIDCConfig.trimmed(discovery.issuer) == OIDCConfig.trimmed(config.issuer) else {
            throw OIDCError.misconfigured(
                logReason: "Discovery nennt einen anderen Issuer (\(discovery.issuer)) als OIDC_ISSUER (\(config.issuer))")
        }
        if let algs = discovery.idTokenSigningAlgValuesSupported, !algs.isEmpty,
           algs.allSatisfy({ !OIDCTokenValidator.allowedAlgorithms.contains($0) }) {
            if algs.contains(where: { $0.uppercased().hasPrefix("HS") }) { throw OIDCError.symmetricSigning }
            throw OIDCError.misconfigured(logReason: "Keine unterstützte Signatur in id_token_signing_alg_values_supported: \(algs)")
        }
        cachedDiscovery = (discovery, now())
        return discovery
    }

    private func dropDiscovery() {
        cachedDiscovery = nil
        keySet = nil
    }

    private func keys(_ discovery: OIDCDiscovery) async throws -> OIDCKeySet {
        if let keySet { return keySet }
        guard let url = URL(string: discovery.jwksURI) else { throw OIDCError.misconfigured(logReason: "jwks_uri ist keine URL") }
        let status: UInt
        let body: Data
        do {
            (status, body) = try await transport.get(url)
        } catch {
            dropDiscovery()
            throw error
        }
        guard status == 200 else {
            dropDiscovery()
            if status >= 500 { throw OIDCError.unreachable }
            throw OIDCError.failed(logReason: "JWKS antwortete mit HTTP \(status)")
        }
        let loaded = try await OIDCKeySet.from(jwks: body)
        keySet = loaded
        keysLoadedAt = now()
        return loaded
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let id_token: String?
    }

    private struct TokenError: Decodable {
        let error: String?
    }

    private func tokenRequest(_ discovery: OIDCDiscovery, code: String, codeVerifier: String) async throws -> String {
        guard let url = URL(string: discovery.tokenEndpoint) else { throw OIDCError.misconfigured(logReason: "token_endpoint ist keine URL") }
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURL.absoluteString,
            "code_verifier": codeVerifier,
        ]
        var basicAuth: (user: String, password: String)?
        let methods = discovery.tokenEndpointAuthMethodsSupported
        if methods == nil || methods?.contains("client_secret_basic") == true {
            basicAuth = (formEncode(config.clientID), formEncode(config.clientSecret))
        } else if methods?.contains("client_secret_post") == true {
            fields["client_id"] = config.clientID
            fields["client_secret"] = config.clientSecret
        } else {
            throw OIDCError.misconfigured(logReason: "Token-Endpunkt bietet weder client_secret_basic noch client_secret_post an")
        }
        let status: UInt
        let body: Data
        do {
            (status, body) = try await transport.postForm(url, fields: fields, basicAuth: basicAuth)
        } catch {
            dropDiscovery()
            throw error
        }
        guard status == 200 else {
            if status == 404 { dropDiscovery() }
            if status >= 500 { throw OIDCError.unreachable }
            let code = (try? JSONDecoder().decode(TokenError.self, from: body))?.error ?? "unbekannt"
            // Only the OAuth error code is kept: descriptions may repeat the authorization code.
            throw OIDCError.failed(logReason: "Token-Endpunkt antwortete mit HTTP \(status) (\(code.prefix(40)))")
        }
        guard let idToken = (try? JSONDecoder().decode(TokenResponse.self, from: body))?.id_token, !idToken.isEmpty else {
            throw OIDCError.failed(logReason: "Token-Antwort ohne id_token")
        }
        return idToken
    }
}
