import Crypto
import Foundation

/// PKCE S256 challenge (RFC 7636): Base64URL of the SHA-256 of the verifier, without padding.
func pkceChallenge(_ verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Only the app login may be the target after signing in (no open redirects).
func isSafeReturnTo(_ path: String) -> Bool {
    path.hasPrefix("/api/auth/authorize?") && !path.contains("\n") && !path.contains("\r")
}

/// Decodes Base64URL without padding (JWT segments, tokens); nil for invalid input.
func base64URLDecoded(_ text: some StringProtocol) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 { value += "=" }
    return Data(base64Encoded: value)
}
