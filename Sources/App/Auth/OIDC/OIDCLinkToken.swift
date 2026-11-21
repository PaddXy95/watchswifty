import Fluent
import Foundation

/// One-time link that binds whoever signs in at the provider to an account (admin button, `link-oidc`). Its own table,
/// not a purpose in `password_tokens`: older images read unknown purposes as a reset token.
final class OIDCLinkToken: Model, @unchecked Sendable {
    static let schema = "oidc_link_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates a token record.
    /// - Parameters:
    ///   - userID: The account the identity will be linked to.
    ///   - tokenHash: The SHA-256 hex digest of the token.
    ///   - createdAt: The creation time.
    ///   - expiresAt: When the token stops working.
    init(userID: UUID, tokenHash: String, createdAt: Date, expiresAt: Date) {
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// Issues and redeems link tokens (32 random bytes, Base64URL; only the SHA-256 hash is stored).
struct OIDCLinkTokenService {
    let db: any Database

    /// `link-oidc` on the server: one hour.
    static let commandLifetime: TimeInterval = 3600
    /// „Verknüpfungslink“ on the users page (mailed like an invitation): seven days.
    static let adminLifetime: TimeInterval = 7 * 86_400

    /// A new token; older tokens of the user stop working.
    /// - Parameters:
    ///   - userID: The account to link.
    ///   - lifetime: How long the token works (`commandLifetime` or `adminLifetime`).
    ///   - now: The creation time.
    /// - Returns: The plain token for the link; only its hash is stored.
    /// - Throws: Database errors.
    func issue(userID: UUID, lifetime: TimeInterval, now: Date = .now) async throws -> String {
        try await OIDCLinkToken.query(on: db).filter(\.$user.$id == userID).delete()
        var generator = SystemRandomNumberGenerator()
        let token = base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        try await OIDCLinkToken(userID: userID, tokenHash: APITokenService.hash(token), createdAt: now,
                                expiresAt: now.addingTimeInterval(lifetime)).save(on: db)
        return token
    }

    /// The usable token record, nil when unknown or expired.
    /// - Parameters:
    ///   - token: The token from the link; empty values and values over 128 characters are ignored.
    ///   - now: The time to check the expiry against.
    /// - Returns: The record, or `nil`.
    /// - Throws: Database errors.
    func check(_ token: String, now: Date = .now) async throws -> OIDCLinkToken? {
        guard !token.isEmpty, token.count <= 128 else { return nil }
        guard let record = try await OIDCLinkToken.query(on: db).filter(\.$tokenHash == APITokenService.hash(token)).first(),
              record.expiresAt > now else { return nil }
        return record
    }

    /// The token's user; the token is gone afterwards.
    /// - Parameters:
    ///   - token: The token from the link.
    ///   - now: The time to check the expiry against.
    /// - Returns: The user ID, or `nil` for an unknown or expired token.
    /// - Throws: Database errors.
    func consume(_ token: String, now: Date = .now) async throws -> UUID? {
        guard let record = try await check(token, now: now) else { return nil }
        try await record.delete(on: db)
        return record.$user.id
    }

    /// Ends every link token of a user.
    /// - Parameter userID: The account.
    /// - Throws: Database errors.
    func deleteAll(userID: UUID) async throws {
        try await OIDCLinkToken.query(on: db).filter(\.$user.$id == userID).delete()
    }

    /// Removes expired link tokens.
    /// - Parameter now: The reference time.
    /// - Returns: The number of deleted tokens.
    /// - Throws: Database errors.
    @discardableResult
    func deleteExpired(now: Date = .now) async throws -> Int {
        let count = try await OIDCLinkToken.query(on: db).filter(\.$expiresAt <= now).count()
        try await OIDCLinkToken.query(on: db).filter(\.$expiresAt <= now).delete()
        return count
    }
}
