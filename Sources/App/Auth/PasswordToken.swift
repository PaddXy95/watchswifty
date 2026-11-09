import Fluent
import Foundation

enum PasswordTokenPurpose: String, Codable, Sendable {
    /// „Passwort vergessen“: valid one hour.
    case reset
    /// Invitation: the invitee sets the first password, valid seven days.
    case invite

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

    init() {}

    init(userID: UUID, purpose: PasswordTokenPurpose, tokenHash: String, createdAt: Date) {
        self.$user.id = userID
        self.purpose = purpose.rawValue
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(purpose.lifetime)
    }

    var tokenPurpose: PasswordTokenPurpose { PasswordTokenPurpose(rawValue: purpose) ?? .reset }
}

struct CreatePasswordToken: AsyncMigration {
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

    func revert(on database: any Database) async throws {
        try await database.schema(PasswordToken.schema).delete()
    }
}
