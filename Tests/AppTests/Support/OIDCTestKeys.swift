@testable import App
import Foundation
import JWTKit

/// Signing keys and ID tokens for the OIDC tests. The RSA key is a throwaway test key, used nowhere else.
enum OIDCTestKeys {
    static let issuer = "https://id.example.test"
    static let clientID = "watchswifty"

    struct Pair: Sendable {
        /// Signs test tokens (private key).
        let signer: JWTKeyCollection
        /// What a provider publishes at its jwks_uri.
        let jwks: String
        let kid: String
        var ecdsaKey: ES256PrivateKey? = nil
    }

    enum KeyError: Error { case noParameters }

    static func es256(kid: String = "k1") async throws -> Pair {
        let key = ES256PrivateKey()
        let signer = JWTKeyCollection()
        await signer.add(ecdsa: key, kid: JWKIdentifier(string: kid))
        guard let parameters = key.publicKey.parameters else { throw KeyError.noParameters }
        let jwks = #"{"keys":[{"kty":"EC","crv":"P-256","use":"sig","alg":"ES256","kid":"\#(kid)","x":"\#(parameters.x)","y":"\#(parameters.y)"}]}"#
        return Pair(signer: signer, jwks: jwks, kid: kid, ecdsaKey: key)
    }

    static func rs256(kid: String = "r1") async throws -> Pair {
        let key = try Insecure.RSA.PrivateKey(pem: rsaPEM)
        let signer = JWTKeyCollection()
        await signer.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
        let primitives = try key.publicKey.getKeyPrimitives()
        let jwks = #"{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"\#(kid)","n":"\#(base64URL(primitives.modulus))","e":"\#(base64URL(primitives.publicExponent))"}]}"#
        return Pair(signer: signer, jwks: jwks, kid: kid)
    }

    /// The keys a relying party builds from a JWKS document.
    static func verifier(_ jwks: String) async throws -> OIDCKeySet {
        try await OIDCKeySet.from(jwks: Data(jwks.utf8))
    }

    static func token(_ claims: TestIDToken, with pair: Pair) async throws -> String {
        try await pair.signer.sign(claims, kid: JWKIdentifier(string: pair.kid))
    }

    /// Header and payload without a valid signature, for algorithm checks.
    static func unsigned(header: String, claims: TestIDToken) throws -> String {
        let payload = try JSONEncoder().encode(claims)
        return base64URL(Data(header.utf8)) + "." + base64URL(payload) + "." + base64URL(Data("sig".utf8))
    }

    static let rsaPEM = """
        -----BEGIN PRIVATE KEY-----
        MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCVA5+dwSwl2e54
        yQsQqWjWAjb6aplThwWl3z0pdyTX5Vr88Cx1LE+eGJ3mnSQ2AWJ5l9J2odCqqUgS
        L5PlhWEE5WIFMyZ2QcTuGR+0m/7FVjL6r70jFxha49+lQ92bb9DefkRVoDTy8AmK
        LbvissGkXfy5qP1zKOBKAekrKZh6iWooXmmJrk1FIvSLkH4BWoCBl4M0CXfbqeKp
        IJ2fh/2aZfvdetokLI+6YtuntuSX1R4rIXd/F4/bEbZOJPJsvD6nTllCvxV1DyJW
        U/nBxdVBUZvk81XmzbBVXnvBMNaRZ6hGtzJGFgEVO/Sux7em7qIcZwSbDvwZImQR
        4nddpi+nAgMBAAECggEADulD6adQ4aDDKjcD8nDhWrjyA3DzUtZqDEUge6u+dhQv
        XKwz5q2+cdWIx3DmFLliv0Qf/VsH5Gv4GEnGhOsp4DGL83VA3giKykCdWZdakSil
        BUzcokxHVaED2ifGXy17Oyhrch4L7ltyuO8GpBK7KdV12qY8Zm+qsf0q9fS9m1VJ
        wS87IlGyC+Ifhq1fDbtVRq48gbcgkzZNPbnqJc2F4bXtkWe8KsPpnc5gsZ6oP9vZ
        gLw4qKQF3qeSSwLyjZx18dtobX0DI5aWR2V2r/HKUDPGVVh+20P8v5z6GHjMqiDi
        H0eSIJxx7ZBqBELybAjyy9VueOysx15QJmHzSeNhAQKBgQDEhTJdYT7Cdx8XZbDX
        4q8+9c+IX4D2v3vJOlK4XN8WbOdYeWtaE/bR8SNg5njdyOkBH65k+yPE57y3ASr8
        XxhFLRGWtSx04LCSCQRxt6Rd1gXtQksMVOA8PeFxKBK04duJcXevXd6d5pD8acvx
        upoZiQe33uATTcxUM1vCmRVNQQKBgQDCHY0oSBnN4rKdBORYARB6Ee3MdPyWQSb6
        H+fmDVlcARQs5xfy43iieMFfbfbUWm8k6D/hX8cxgu3nizrbQKkRCwJZvp/MCuTu
        iUfMiEcCY3wk8x4rSYV10y+G1UbXUwyKQSgI318u8421fbRjW3O65uaqaIXQ0wXS
        eh714vz65wKBgBc0z2S9hga6wF4n8QEdUKpzpoUpGfaJWBnEHF6PAP0J8Su+ctHZ
        R60094OK070E65bpYdOk4G1xHBTUO3o/1ILetpQAYvaOTeuAyxiOogc+rcZ9rJUR
        NMWIXSXaoJLhlOYfEw4PXKlyv64+5Alwip/3UYUB+Z3t8vICepR5NU3BAoGBAK+T
        py/+N0jgegpIeHmZTNv9B4hdcHI/sA+heFG/VUpAt4z94c2SLnVWoCG/BvmAavOJ
        Fu61gSipcqJybuQOEl4WBSRDpaobWILhrQ21XfUtIwcQ2ALzV0IBqQVeN9tfhQIw
        eRO9ZwzCwzSb5OPRvlYZsB4GuLLvjF6akxJ5I7WVAoGBAKk9FaecJE8XlKz/JrFG
        DP+dRxfaVbPH1DuQy4LNq1xH32eGzQ3FUYZc/KTjgbGAiCie55vpjaH7PA+q4wZW
        nfJtvqAiyvONVZC7CacdBP1tEeepkhuRcf1PiC4NwqIt9HpoHx1lFDtzz6Yx4bVw
        yPvc01Z0P9zMfiljKGe16elO
        -----END PRIVATE KEY-----
        """
}

/// ID token claims as a provider sends them; a single audience is encoded as a plain string.
struct TestIDToken: JWTPayload {
    var iss: String = OIDCTestKeys.issuer
    var sub: String = "sub-1"
    var audience: [String] = [OIDCTestKeys.clientID]
    var exp: Date
    var iat: Date?
    var nonce: String? = "n1"
    var azp: String?
    var preferredUsername: String? = "anna"
    var email: String? = "anna@example.org"
    var name: String? = "Anna Beispiel"

    init(now: Date) {
        exp = now.addingTimeInterval(300)
        iat = now
    }

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nonce, azp, email, name
        case preferredUsername = "preferred_username"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iss = try c.decode(String.self, forKey: .iss)
        sub = try c.decode(String.self, forKey: .sub)
        audience = try (try? c.decode([String].self, forKey: .aud)) ?? [c.decode(String.self, forKey: .aud)]
        exp = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .exp))
        iat = try c.decodeIfPresent(Double.self, forKey: .iat).map { Date(timeIntervalSince1970: $0) }
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        azp = try c.decodeIfPresent(String.self, forKey: .azp)
        preferredUsername = try c.decodeIfPresent(String.self, forKey: .preferredUsername)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(iss, forKey: .iss)
        try c.encode(sub, forKey: .sub)
        if audience.count == 1 { try c.encode(audience[0], forKey: .aud) } else { try c.encode(audience, forKey: .aud) }
        try c.encode(Int(exp.timeIntervalSince1970), forKey: .exp)
        try c.encodeIfPresent(iat.map { Int($0.timeIntervalSince1970) }, forKey: .iat)
        try c.encodeIfPresent(nonce, forKey: .nonce)
        try c.encodeIfPresent(azp, forKey: .azp)
        try c.encodeIfPresent(preferredUsername, forKey: .preferredUsername)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(name, forKey: .name)
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {}
}
