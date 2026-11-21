import Crypto
import Fluent
import Foundation

/// Issues, checks and revokes App API tokens (`ws_` + 32 random bytes, 90 days, stored as SHA-256 hex).
struct APITokenService {
    let db: any Database

    /// How long a token stays valid (90 days).
    static let lifetime: TimeInterval = 90 * 86_400
    /// Prefix of every token; other bearer values are rejected without a lookup.
    static let prefix = "ws_"

    /// SHA-256 hex digest of a token, as stored in `token_hash`.
    /// - Parameter token: The plain token.
    /// - Returns: The hex digest.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates and stores a new token.
    /// - Parameters:
    ///   - userID: The owning user.
    ///   - name: The device or token name.
    ///   - kind: How the token was created.
    ///   - now: The creation time.
    /// - Returns: The plain token (the only time it is available) and the stored record.
    /// - Throws: Database errors.
    func issue(userID: UUID, name: String, kind: APITokenKind, now: Date = .now) async throws -> (token: String, record: APIToken) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = Self.prefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = APIToken(userID: userID, name: name, kind: kind, tokenHash: Self.hash(token),
                              createdAt: now, expiresAt: now.addingTimeInterval(Self.lifetime))
        try await record.save(on: db)
        return (token, record)
    }

    /// The token's user; `last_used_at` is refreshed at most hourly.
    /// - Parameters:
    ///   - bearer: The presented bearer token.
    ///   - now: The current time.
    /// - Returns: The user the token belongs to.
    /// - Throws: `APIError.unauthorized` for a value without the prefix, an unknown token or a deleted user,
    ///   `APIError.tokenExpired` for an expired token, database errors.
    func authenticate(_ bearer: String, now: Date = .now) async throws -> User {
        guard bearer.hasPrefix(Self.prefix),
              let record = try await APIToken.query(on: db).filter(\.$tokenHash == Self.hash(bearer)).first() else {
            throw APIError.unauthorized
        }
        guard record.expiresAt > now else { throw APIError.tokenExpired }
        guard let user = try await User.find(record.$user.id, on: db) else { throw APIError.unauthorized }
        if (record.lastUsedAt.map { now.timeIntervalSince($0) >= 3600 }) ?? true {
            record.lastUsedAt = now
            try await record.save(on: db)
        }
        return user
    }

    /// The user's tokens, newest first.
    /// - Parameter userID: The owning user.
    /// - Returns: The token records.
    /// - Throws: Database errors.
    func list(userID: UUID) async throws -> [APIToken] {
        try await APIToken.query(on: db).filter(\.$user.$id == userID).sort(\.$createdAt, .descending).all()
    }

    /// Deletes one of the user's tokens.
    /// - Parameters:
    ///   - id: The token record's ID.
    ///   - userID: The acting user.
    /// - Throws: `APIError.notFound` for an unknown or another user's token, database errors.
    func revoke(id: UUID, userID: UUID) async throws {
        guard let record = try await APIToken.find(id, on: db), record.$user.id == userID else { throw APIError.notFound }
        try await record.delete(on: db)
    }

    /// Revokes the presented token itself (app logout).
    /// - Parameter bearer: The plain token.
    /// - Throws: Database errors.
    func revoke(bearer: String) async throws {
        try await APIToken.query(on: db).filter(\.$tokenHash == Self.hash(bearer)).delete()
    }

    /// Deletes all expired tokens.
    /// - Parameter now: The current time.
    /// - Returns: The number of deleted tokens.
    /// - Throws: Database errors.
    func deleteExpired(now: Date = .now) async throws -> Int {
        let expired = try await APIToken.query(on: db).filter(\.$expiresAt <= now).all()
        for record in expired { try await record.delete(on: db) }
        return expired.count
    }
}
