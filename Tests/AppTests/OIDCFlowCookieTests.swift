@testable import App
import Crypto
import Foundation
import Testing
import Vapor

@Suite("OIDCFlowCookie")
struct OIDCFlowCookieTests {
    let cipher = TokenCipher(key: SymmetricKey(size: .bits256))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var cookie: OIDCFlowCookie {
        OIDCFlowCookie(state: "st", nonce: "no", verifier: "ve", startedAt: now, intent: .login, returnTo: "/api/auth/authorize?x=1")
    }

    @Test func roundTrip() throws {
        let sealed = try cookie.seal(cipher)
        let opened = try #require(OIDCFlowCookie.open(sealed, cipher: cipher, now: now.addingTimeInterval(599)))
        #expect(opened.state == "st")
        #expect(opened.nonce == "no")
        #expect(opened.verifier == "ve")
        #expect(opened.intent == .login)
        #expect(opened.returnTo == "/api/auth/authorize?x=1")
        #expect(!sealed.contains("st\""))
    }

    @Test func tamperedCookieRejected() throws {
        var sealed = try cookie.seal(cipher)
        let last = sealed.removeLast()
        sealed.append(last == "A" ? "B" : "A")
        #expect(OIDCFlowCookie.open(sealed, cipher: cipher, now: now) == nil)
    }

    @Test func plaintextCookieRejected() throws {
        let json = String(decoding: try JSONEncoder().encode(cookie), as: UTF8.self)
        #expect(OIDCFlowCookie.open(json, cipher: cipher, now: now) == nil)
    }

    @Test func oldCookieRejected() throws {
        let sealed = try cookie.seal(cipher)
        #expect(OIDCFlowCookie.open(sealed, cipher: cipher, now: now.addingTimeInterval(601)) == nil)
    }

    @Test func parkedIdentityExtendsTheWindow() throws {
        var parked = cookie
        parked.pending = OIDCIdentity(issuer: "i", subject: "s")
        parked.pendingAt = now.addingTimeInterval(500)
        let sealed = try parked.seal(cipher)
        #expect(OIDCFlowCookie.open(sealed, cipher: cipher, now: now.addingTimeInterval(1000)) != nil)
        #expect(OIDCFlowCookie.open(sealed, cipher: cipher, now: now.addingTimeInterval(1101)) == nil)
    }

    @Test func otherKeyRejected() throws {
        let sealed = try cookie.seal(cipher)
        let other = TokenCipher(key: SymmetricKey(size: .bits256))
        #expect(OIDCFlowCookie.open(sealed, cipher: other, now: now) == nil)
        #expect(OIDCFlowCookie.open(nil, cipher: cipher, now: now) == nil)
    }

    @Test func cookieAttributes() throws {
        let value = try cookie.cookie(cipher, secure: true)
        #expect(value.path == "/auth/oidc")
        #expect(value.isHTTPOnly)
        #expect(value.isSecure)
        #expect(value.maxAge == 600)
        #expect(value.sameSite == .lax)
        #expect(OIDCFlowCookie.expired.path == "/auth/oidc")
        #expect(OIDCFlowCookie.expired.maxAge == 0)
    }
}
