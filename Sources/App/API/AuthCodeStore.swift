import Foundation
import Vapor

/// One-time codes of the app login (60 s, single use, bound to user, PKCE challenge, redirect URI and device name).
/// Kept in memory: a restart only means the app has to connect again.
actor AuthCodeStore {
    static let lifetime: TimeInterval = 60

    private struct Pending {
        let userID: UUID
        let challenge: String
        let redirectURI: String
        let deviceName: String
        let expiresAt: Date
    }

    private var pending: [String: Pending] = [:]

    func issue(userID: UUID, challenge: String, redirectURI: String, deviceName: String, now: Date = .now) -> String {
        pending = pending.filter { $0.value.expiresAt > now }
        var generator = SystemRandomNumberGenerator()
        let code = base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        pending[code] = Pending(userID: userID, challenge: challenge, redirectURI: redirectURI, deviceName: deviceName,
                                expiresAt: now.addingTimeInterval(Self.lifetime))
        return code
    }

    func redeem(code: String, verifier: String, redirectURI: String, now: Date = .now) throws -> (userID: UUID, deviceName: String) {
        guard let entry = pending.removeValue(forKey: code), entry.expiresAt > now, entry.redirectURI == redirectURI,
              pkceChallenge(verifier) == entry.challenge else {
            throw APIError.invalidGrant
        }
        return (entry.userID, entry.deviceName)
    }
}

extension Application {
    private struct AuthCodeStoreKey: StorageKey { typealias Value = AuthCodeStore }

    var authCodes: AuthCodeStore {
        get {
            guard let store = storage[AuthCodeStoreKey.self] else { fatalError("Auth code store not configured") }
            return store
        }
        set { storage[AuthCodeStoreKey.self] = newValue }
    }
}
