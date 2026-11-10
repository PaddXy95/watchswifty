import Foundation
import JWTKit

/// The provider's public keys (from its JWKS) and their key IDs. jwt-kit falls back to its default key for an unknown
/// `kid`, so the IDs are kept to notice key rotation.
struct OIDCKeySet: Sendable {
    let keys: JWTKeyCollection
    let keyIDs: Set<String>
    var keyCount = 0

    /// Keys from a JWKS document; keys of other types (e.g. `oct`) are skipped by jwt-kit or rejected later.
    static func from(jwks data: Data) async throws -> OIDCKeySet {
        let jwks = try JSONDecoder().decode(JWKS.self, from: data)
        let keys = JWTKeyCollection()
        try await keys.add(jwks: jwks)
        return OIDCKeySet(keys: keys, keyIDs: Set(jwks.keys.compactMap { $0.keyIdentifier?.string }), keyCount: jwks.keys.count)
    }
}

/// Checks an ID token (spec „Ablauf“, callback step 4): algorithm, signature, `iss`, `aud`/`azp`, `exp`/`iat`, `nonce`.
struct OIDCTokenValidator: Sendable {
    /// Only asymmetric signatures: HS* would use the client secret as key, `none` is unsigned.
    static let allowedAlgorithms: Set<String> = [
        "RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512", "EdDSA",
    ]
    static let leeway: TimeInterval = 60

    private struct Header: Decodable {
        let alg: String?
        let kid: String?
    }

    /// The claims WatchSwifty reads; time checks happen in `validate` against the given `now`.
    private struct Claims: JWTPayload {
        let iss: String
        let sub: String
        let aud: AudienceClaim
        let exp: Double
        let iat: Double?
        let nonce: String?
        let azp: String?
        let preferred_username: String?
        let email: String?
        let name: String?

        func verify(using algorithm: some JWTAlgorithm) async throws {}
    }

    func validate(_ idToken: String, keys keySet: OIDCKeySet, issuer: String, clientID: String, nonce: String,
                  now: Date) async throws -> OIDCIdentity {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = base64URLDecoded(parts[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData), let alg = header.alg else {
            throw OIDCError.failed(logReason: "ID-Token hat kein gültiges Format")
        }
        guard Self.allowedAlgorithms.contains(alg) else {
            if alg.uppercased().hasPrefix("HS") { throw OIDCError.symmetricSigning }
            throw OIDCError.failed(logReason: "ID-Token mit nicht erlaubtem Algorithmus \(alg)")
        }
        if let kid = header.kid, !keySet.keyIDs.contains(kid) {
            throw OIDCError.unknownKey(kid: kid)
        }
        let claims: Claims
        do {
            claims = try await keySet.keys.verify(idToken, as: Claims.self, iteratingKeys: header.kid == nil)
        } catch {
            throw OIDCError.failed(logReason: "ID-Token-Signatur ungültig")
        }
        guard claims.iss == issuer else { throw OIDCError.failed(logReason: "ID-Token von fremdem Issuer \(claims.iss)") }
        guard claims.aud.value.contains(clientID) else { throw OIDCError.failed(logReason: "ID-Token für einen anderen Client") }
        if claims.aud.value.count > 1 || claims.azp != nil {
            guard claims.azp == clientID else { throw OIDCError.failed(logReason: "ID-Token mit falschem azp") }
        }
        guard now.timeIntervalSince1970 <= claims.exp + Self.leeway else {
            throw OIDCError.failed(logReason: "ID-Token abgelaufen")
        }
        if let iat = claims.iat, iat > now.timeIntervalSince1970 + Self.leeway {
            throw OIDCError.failed(logReason: "ID-Token aus der Zukunft (iat)")
        }
        guard let tokenNonce = claims.nonce, tokenNonce == nonce else {
            throw OIDCError.failed(logReason: "ID-Token mit falschem nonce")
        }
        guard !claims.sub.isEmpty else { throw OIDCError.failed(logReason: "ID-Token ohne sub") }
        return OIDCIdentity(issuer: claims.iss, subject: claims.sub, preferredUsername: claims.preferred_username,
                            email: claims.email, name: claims.name)
    }
}
