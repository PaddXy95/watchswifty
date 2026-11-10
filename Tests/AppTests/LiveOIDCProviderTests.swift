@testable import App
import Foundation
import Logging
import Testing

@Suite("LiveOIDCProvider")
struct LiveOIDCProviderTests {
    let config = AppConfig.testingOIDC.oidc!

    private func provider(_ transport: FakeOIDCTransport, clock: TestClock = TestClock(), config: OIDCConfig? = nil) -> LiveOIDCProvider {
        LiveOIDCProvider(config: config ?? self.config, transport: transport, logger: Logger(label: "test"), now: { clock.now })
    }

    /// Transport with discovery, JWKS of `pair` and a token endpoint returning `claims` signed by `pair`.
    private func transport(pair: OIDCTestKeys.Pair, claims: TestIDToken, authMethods: [String]? = nil) async throws -> FakeOIDCTransport {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery(authMethods: authMethods))
        transport.set(FakeOIDCTransport.jwksURL, json: pair.jwks)
        let token = try await OIDCTestKeys.token(claims, with: pair)
        transport.set(FakeOIDCTransport.tokenURL, json: #"{"access_token":"at","token_type":"Bearer","id_token":"\#(token)"}"#)
        return transport
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    @Test func authorizationURLHasAllParameters() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        let url = try await provider(transport).authorizationURL(state: "st", nonce: "no", codeChallenge: "ch")
        #expect(url.absoluteString.hasPrefix("https://id.example.test/authorize?"))
        let q = query(url)
        #expect(q["tenant"] == "home")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "openid profile email")
        #expect(q["client_id"] == "watchswifty")
        #expect(q["redirect_uri"] == "http://localhost:8080/auth/oidc/callback")
        #expect(q["state"] == "st")
        #expect(q["nonce"] == "no")
        #expect(q["code_challenge"] == "ch")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["prompt"] == nil)
    }

    @Test func discoveryWithAndWithoutTrailingSlash() async throws {
        for issuer in ["https://id.example.test/app/", "https://id.example.test/app"] {
            var config = self.config
            config.issuer = issuer
            let transport = FakeOIDCTransport()
            transport.set("https://id.example.test/app/.well-known/openid-configuration",
                          json: FakeOIDCTransport.discovery(issuer: "https://id.example.test/app/"))
            _ = try await provider(transport, config: config).authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
            #expect(transport.requests.map(\.url) == ["https://id.example.test/app/.well-known/openid-configuration"])
        }
    }

    @Test func discoveryIssuerMismatchFails() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery(issuer: "https://other.example"))
        await #expect(throws: OIDCError.misconfigured(logReason: "Discovery nennt einen anderen Issuer (https://other.example) als eingetragen (https://id.example.test)")) {
            _ = try await provider(transport).authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        }
    }

    @Test func discoveredIssuerIsTheDiscoveryValue() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery(issuer: "https://id.example.test/"))
        #expect(try await provider(transport).discoveredIssuer() == "https://id.example.test/")
    }

    @Test func discoveryCachedFor24Hours() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        let clock = TestClock()
        let provider = provider(transport, clock: clock)
        _ = try await provider.authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        clock.advance(86_400)
        _ = try await provider.authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        #expect(transport.requests(to: FakeOIDCTransport.discoveryURL).count == 1)
        clock.advance(1)
        _ = try await provider.authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        #expect(transport.requests(to: FakeOIDCTransport.discoveryURL).count == 2)
    }

    @Test func exchangeReturnsValidatedIdentity() async throws {
        let clock = TestClock()
        let pair = try await OIDCTestKeys.es256()
        let transport = try await transport(pair: pair, claims: TestIDToken(now: clock.now))
        let identity = try await provider(transport, clock: clock).exchange(code: "the-code", codeVerifier: "the-verifier", nonce: "n1")
        #expect(identity.subject == "sub-1")
        #expect(identity.issuer == OIDCTestKeys.issuer)
        let post = try #require(transport.requests(to: FakeOIDCTransport.tokenURL).first)
        #expect(post.method == "POST")
        #expect(post.fields["grant_type"] == "authorization_code")
        #expect(post.fields["code"] == "the-code")
        #expect(post.fields["code_verifier"] == "the-verifier")
        #expect(post.fields["redirect_uri"] == "http://localhost:8080/auth/oidc/callback")
    }

    @Test func usesBasicAuthWhenOffered() async throws {
        for methods in [nil, ["client_secret_post", "client_secret_basic"]] as [[String]?] {
            let clock = TestClock()
            let pair = try await OIDCTestKeys.es256()
            let transport = try await transport(pair: pair, claims: TestIDToken(now: clock.now), authMethods: methods)
            var config = self.config
            config.clientSecret = "a b+c"
            _ = try await provider(transport, clock: clock, config: config).exchange(code: "c", codeVerifier: "v", nonce: "n1")
            let post = try #require(transport.requests(to: FakeOIDCTransport.tokenURL).first)
            #expect(post.basicAuth?.user == "watchswifty")
            #expect(post.basicAuth?.password == "a+b%2Bc")
            #expect(post.fields["client_secret"] == nil)
        }
    }

    @Test func usesPostWhenOnlyPostOffered() async throws {
        let clock = TestClock()
        let pair = try await OIDCTestKeys.es256()
        let transport = try await transport(pair: pair, claims: TestIDToken(now: clock.now), authMethods: ["client_secret_post"])
        _ = try await provider(transport, clock: clock).exchange(code: "c", codeVerifier: "v", nonce: "n1")
        let post = try #require(transport.requests(to: FakeOIDCTransport.tokenURL).first)
        #expect(post.basicAuth == nil)
        #expect(post.fields["client_id"] == "watchswifty")
        #expect(post.fields["client_secret"] == "secret")
    }

    @Test func unknownKidReloadsOnceThenFails() async throws {
        let clock = TestClock()
        let first = try await OIDCTestKeys.es256(kid: "k1")
        let transport = try await transport(pair: first, claims: TestIDToken(now: clock.now))
        let provider = provider(transport, clock: clock)
        _ = try await provider.exchange(code: "c", codeVerifier: "v", nonce: "n1")
        #expect(transport.requests(to: FakeOIDCTransport.jwksURL).count == 1)

        // Two minutes later the provider has rotated to k2: one reload, then it works.
        clock.advance(120)
        let rotated = try await OIDCTestKeys.es256(kid: "k2")
        transport.set(FakeOIDCTransport.jwksURL, json: rotated.jwks)
        transport.set(FakeOIDCTransport.tokenURL, json: #"{"id_token":"\#(try await OIDCTestKeys.token(TestIDToken(now: clock.now), with: rotated))"}"#)
        #expect(try await provider.exchange(code: "c", codeVerifier: "v", nonce: "n1").subject == "sub-1")
        #expect(transport.requests(to: FakeOIDCTransport.jwksURL).count == 2)

        // Another unknown kid within a minute: no reload.
        clock.advance(10)
        let unknown = try await OIDCTestKeys.es256(kid: "k3")
        transport.set(FakeOIDCTransport.tokenURL, json: #"{"id_token":"\#(try await OIDCTestKeys.token(TestIDToken(now: clock.now), with: unknown))"}"#)
        await #expect(throws: OIDCError.unknownKey(kid: "k3")) {
            _ = try await provider.exchange(code: "c", codeVerifier: "v", nonce: "n1")
        }
        #expect(transport.requests(to: FakeOIDCTransport.jwksURL).count == 2)
    }

    @Test func discoveryDroppedAfterTokenEndpoint404() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        transport.set(FakeOIDCTransport.tokenURL, status: 404, json: "{}")
        let provider = provider(transport)
        await #expect(throws: OIDCError.self) { _ = try await provider.exchange(code: "c", codeVerifier: "v", nonce: "n") }
        _ = try await provider.authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        #expect(transport.requests(to: FakeOIDCTransport.discoveryURL).count == 2)
    }

    @Test func symmetricOnlyProviderRejected() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery(algs: ["HS256"]))
        await #expect(throws: OIDCError.symmetricSigning) {
            _ = try await provider(transport).authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        }
    }

    @Test func unreachableProviderMapsToUnreachable() async throws {
        let transport = FakeOIDCTransport()
        transport.setUnreachable(FakeOIDCTransport.discoveryURL)
        await #expect(throws: OIDCError.unreachable) {
            _ = try await provider(transport).authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        }
        transport.set(FakeOIDCTransport.discoveryURL, status: 503, json: "{}")
        await #expect(throws: OIDCError.unreachable) {
            _ = try await provider(transport).authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        }
    }

    @Test func tokenErrorDoesNotLeakCode() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        transport.set(FakeOIDCTransport.tokenURL, status: 400,
                      json: #"{"error":"invalid_grant","error_description":"code SECRET-CODE-123 expired"}"#)
        do {
            _ = try await provider(transport).exchange(code: "SECRET-CODE-123", codeVerifier: "v", nonce: "n")
            Issue.record("expected failure")
        } catch let error as OIDCError {
            #expect(error.logDescription.contains("invalid_grant"))
            #expect(!error.logDescription.contains("SECRET-CODE-123"))
            #expect(!String(describing: error).contains("SECRET-CODE-123"))
        }
    }

    @Test func tokenResponseWithoutIDTokenFails() async throws {
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        transport.set(FakeOIDCTransport.tokenURL, json: #"{"access_token":"at"}"#)
        await #expect(throws: OIDCError.self) { _ = try await provider(transport).exchange(code: "c", codeVerifier: "v", nonce: "n") }
    }

    @Test func checkLoadsDiscoveryAndKeys() async throws {
        let pair = try await OIDCTestKeys.es256()
        let transport = FakeOIDCTransport()
        transport.set(FakeOIDCTransport.discoveryURL, json: FakeOIDCTransport.discovery())
        transport.set(FakeOIDCTransport.jwksURL, json: pair.jwks)
        let provider = provider(transport)
        let result = try await provider.check()
        #expect(result == OIDCCheck(issuer: OIDCTestKeys.issuer, keyCount: 1))
        _ = try await provider.check()
        #expect(transport.requests(to: FakeOIDCTransport.discoveryURL).count == 2)   // always fresh
    }
}
