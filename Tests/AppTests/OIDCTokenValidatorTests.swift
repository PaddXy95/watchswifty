@testable import App
import Foundation
import JWTKit
import Testing

@Suite("OIDCTokenValidator")
struct OIDCTokenValidatorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let validator = OIDCTokenValidator()

    private func validate(_ token: String, jwks: String, nonce: String = "n1", at date: Date? = nil) async throws -> OIDCIdentity {
        try await validator.validate(token, keys: try await OIDCTestKeys.verifier(jwks), issuer: OIDCTestKeys.issuer,
                                     clientID: OIDCTestKeys.clientID, nonce: nonce, now: date ?? now)
    }

    private func expectError(_ expected: OIDCError, _ body: () async throws -> OIDCIdentity) async {
        do {
            _ = try await body()
            Issue.record("expected \(expected)")
        } catch let error as OIDCError {
            switch (expected, error) {
            case (.failed, .failed), (.symmetricSigning, .symmetricSigning): break
            default: #expect(error == expected)
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func validES256TokenYieldsIdentity() async throws {
        let pair = try await OIDCTestKeys.es256()
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: pair)
        let identity = try await validate(token, jwks: pair.jwks)
        #expect(identity == OIDCIdentity(issuer: OIDCTestKeys.issuer, subject: "sub-1", preferredUsername: "anna",
                                         email: "anna@example.org", name: "Anna Beispiel"))
    }

    @Test func validRS256TokenYieldsIdentity() async throws {
        let pair = try await OIDCTestKeys.rs256()
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: pair)
        #expect(try await validate(token, jwks: pair.jwks).subject == "sub-1")
    }

    @Test func audienceAsPlainString() async throws {
        let pair = try await OIDCTestKeys.es256()
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: pair)
        let payload = String(token.split(separator: ".")[1])
        let data = try #require(base64URLDecoded(payload))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""aud":"watchswifty""#))
        #expect(try await validate(token, jwks: pair.jwks).subject == "sub-1")
    }

    @Test func wrongIssuerRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.iss = "https://evil.example"
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func issuerWithTrailingSlashIsNotTheSame() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.iss = OIDCTestKeys.issuer + "/"
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func foreignAudienceRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.audience = ["other-app"]
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func multipleAudiencesNeedAzp() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.audience = [OIDCTestKeys.clientID, "other-app"]
        let withoutAzp = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(withoutAzp, jwks: pair.jwks) }
        claims.azp = OIDCTestKeys.clientID
        let withAzp = try await OIDCTestKeys.token(claims, with: pair)
        #expect(try await validate(withAzp, jwks: pair.jwks).subject == "sub-1")
    }

    @Test func foreignAzpRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.azp = "other-app"
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func expiredTokenRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        let claims = TestIDToken(now: now)
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) {
            try await validate(token, jwks: pair.jwks, at: claims.exp.addingTimeInterval(61))
        }
    }

    @Test func expiryWithinLeewayAccepted() async throws {
        let pair = try await OIDCTestKeys.es256()
        let claims = TestIDToken(now: now)
        let token = try await OIDCTestKeys.token(claims, with: pair)
        #expect(try await validate(token, jwks: pair.jwks, at: claims.exp.addingTimeInterval(59)).subject == "sub-1")
    }

    @Test func futureIatRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.iat = now.addingTimeInterval(120)
        claims.exp = now.addingTimeInterval(600)
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func nonceMismatchRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks, nonce: "other") }
    }

    @Test func missingNonceRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.nonce = nil
        let token = try await OIDCTestKeys.token(claims, with: pair)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func hs256Rejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        let hmac = JWTKeyCollection()
        await hmac.add(hmac: "client-secret-that-is-long-enough-for-hs256", digestAlgorithm: .sha256, kid: "k1")
        let token = try await hmac.sign(TestIDToken(now: now), kid: "k1")
        await expectError(.symmetricSigning) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func algNoneRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        let token = try OIDCTestKeys.unsigned(header: #"{"alg":"none","typ":"JWT"}"#, claims: TestIDToken(now: now))
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func forgedSignatureRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        let token = try OIDCTestKeys.unsigned(header: #"{"alg":"ES256","typ":"JWT","kid":"k1"}"#, claims: TestIDToken(now: now))
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: pair.jwks) }
    }

    @Test func otherKeysSignatureRejected() async throws {
        let published = try await OIDCTestKeys.es256(kid: "k1")
        let attacker = try await OIDCTestKeys.es256(kid: "k1")
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: attacker)
        await expectError(.failed(logReason: "")) { try await validate(token, jwks: published.jwks) }
    }

    @Test func unknownKidReported() async throws {
        let published = try await OIDCTestKeys.es256(kid: "k1")
        let other = try await OIDCTestKeys.es256(kid: "zz")
        let token = try await OIDCTestKeys.token(TestIDToken(now: now), with: other)
        await expectError(.unknownKey(kid: "zz")) { try await validate(token, jwks: published.jwks) }
    }

    @Test func tokenWithoutKidUsesThePublishedKey() async throws {
        let pair = try await OIDCTestKeys.es256()
        let withoutKid = JWTKeyCollection()
        await withoutKid.add(ecdsa: try #require(pair.ecdsaKey))
        let token = try await withoutKid.sign(TestIDToken(now: now))
        #expect(try await validate(token, jwks: pair.jwks).subject == "sub-1")
    }

    @Test func garbageRejected() async throws {
        let pair = try await OIDCTestKeys.es256()
        await expectError(.failed(logReason: "")) { try await validate("not-a-token", jwks: pair.jwks) }
    }

    @Test func optionalClaimsMayBeMissing() async throws {
        let pair = try await OIDCTestKeys.es256()
        var claims = TestIDToken(now: now)
        claims.preferredUsername = nil
        claims.email = nil
        claims.name = nil
        claims.iat = nil
        let identity = try await validate(try await OIDCTestKeys.token(claims, with: pair), jwks: pair.jwks)
        #expect(identity == OIDCIdentity(issuer: OIDCTestKeys.issuer, subject: "sub-1", preferredUsername: nil, email: nil, name: nil))
    }

    @Test func errorMessagesUseTheName() {
        #expect(OIDCError.unreachable.message(name: "Pocket ID") == "Pocket ID ist gerade nicht erreichbar.")
        #expect(OIDCError.denied.message(name: "SSO") == "SSO hat die Anmeldung abgelehnt.")
        #expect(OIDCError.failed(logReason: "x").message(name: "SSO") == "Anmeldung über SSO fehlgeschlagen.")
        #expect(OIDCError.symmetricSigning.message(name: "SSO") == "Anmeldung über SSO fehlgeschlagen.")
    }
}
