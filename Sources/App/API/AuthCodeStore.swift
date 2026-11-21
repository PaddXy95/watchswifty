import Foundation
import Vapor

/// One-time codes of the app login (60 s, single use, bound to user, PKCE challenge, redirect URI and device name).
/// Kept in memory: a restart only means the app has to connect again.
actor AuthCodeStore {
    /// How long a code stays valid, in seconds.
    static let lifetime: TimeInterval = 60

    /// A code waiting to be redeemed, with everything it is bound to.
    private struct Pending {
        let userID: UUID
        let challenge: String
        let redirectURI: String
        let deviceName: String
        let expiresAt: Date
    }

    private var pending: [String: Pending] = [:]

    /// Issues a new single-use code (Base64URL of 32 random bytes) and drops expired ones.
    /// - Parameters:
    ///   - userID: The user who confirmed the connection.
    ///   - challenge: The app's PKCE S256 challenge.
    ///   - redirectURI: The redirect URI the code is bound to.
    ///   - deviceName: The device name for the token.
    ///   - now: The current time.
    /// - Returns: The code to hand to the app.
    func issue(userID: UUID, challenge: String, redirectURI: String, deviceName: String, now: Date = .now) -> String {
        pending = pending.filter { $0.value.expiresAt > now }
        var generator = SystemRandomNumberGenerator()
        let code = base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        pending[code] = Pending(userID: userID, challenge: challenge, redirectURI: redirectURI, deviceName: deviceName,
                                expiresAt: now.addingTimeInterval(Self.lifetime))
        return code
    }

    /// Redeems a code: it must exist, not be expired, match the redirect URI and the PKCE verifier.
    ///
    /// The code is removed on every attempt, so a failed check also uses it up.
    /// - Parameters:
    ///   - code: The code the app received.
    ///   - verifier: The app's PKCE code verifier.
    ///   - redirectURI: The redirect URI the app sends with the exchange.
    ///   - now: The current time.
    /// - Returns: The user and the device name the code was issued for.
    /// - Throws: `APIError.invalidGrant` when any check fails.
    func redeem(code: String, verifier: String, redirectURI: String, now: Date = .now) throws -> (userID: UUID, deviceName: String) {
        guard let entry = pending.removeValue(forKey: code), entry.expiresAt > now, entry.redirectURI == redirectURI,
              pkceChallenge(verifier) == entry.challenge else {
            throw APIError.invalidGrant
        }
        return (entry.userID, entry.deviceName)
    }
}

extension Application {
    /// Storage key for `authCodes`.
    private struct AuthCodeStoreKey: StorageKey { typealias Value = AuthCodeStore }

    /// The app-wide store of pending app login codes (set in `configure`).
    var authCodes: AuthCodeStore {
        get {
            guard let store = storage[AuthCodeStoreKey.self] else { fatalError("Auth code store not configured") }
            return store
        }
        set { storage[AuthCodeStoreKey.self] = newValue }
    }
}
