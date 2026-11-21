import Fluent
import Foundation

/// What a password link is for; stored as the raw value in `password_tokens.purpose`.
enum PasswordTokenPurpose: String, Codable, Sendable {
    /// „Passwort vergessen“: valid one hour.
    case reset
    /// Invitation: the invitee sets the first password, valid seven days.
    case invite

    /// How long a link of this purpose stays valid: one hour for a reset, seven days for an invitation.
    var lifetime: TimeInterval {
        switch self {
        case .reset: 3600
        case .invite: 7 * 86_400
        }
    }
}

/// One-time link to set a password. Only the SHA-256 hash is stored; the token itself exists only in the mail.
final class PasswordToken: Model, @unchecked Sendable {
    static let schema = "password_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "purpose") var purpose: String
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates a token record that expires after the purpose's lifetime.
    /// - Parameters:
    ///   - userID: The account the link is for.
    ///   - purpose: Reset or invitation.
    ///   - tokenHash: The SHA-256 hex digest of the token.
    ///   - createdAt: The creation time; the expiry is counted from it.
    init(userID: UUID, purpose: PasswordTokenPurpose, tokenHash: String, createdAt: Date) {
        self.$user.id = userID
        self.purpose = purpose.rawValue
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(purpose.lifetime)
    }

    /// The typed purpose; an unknown stored value counts as `.reset`.
    var tokenPurpose: PasswordTokenPurpose { PasswordTokenPurpose(rawValue: purpose) ?? .reset }
}

/// Creates `password_tokens` (unique token hash; rows are deleted with their user).
struct CreatePasswordToken: AsyncMigration {
    /// Creates the table.
    func prepare(on database: any Database) async throws {
        try await database.schema(PasswordToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("purpose", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(PasswordToken.schema).delete()
    }
}
