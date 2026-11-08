import Fluent
import Foundation

enum APITokenKind: String, Codable, Sendable {
    /// Issued to an app through the browser login.
    case device
    /// Created by hand under Konto (scripts, trying out the docs).
    case manual
}

/// A device's bearer token for the App API. Only the SHA-256 hash is stored.
final class APIToken: Model, @unchecked Sendable {
    static let schema = "api_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "name") var name: String
    @Field(key: "kind") var kind: String
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?

    init() {}

    init(userID: UUID, name: String, kind: APITokenKind, tokenHash: String, createdAt: Date, expiresAt: Date) {
        self.$user.id = userID
        self.name = name
        self.kind = kind.rawValue
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    var tokenKind: APITokenKind { APITokenKind(rawValue: kind) ?? .device }
}

struct CreateAPIToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("name", .string, .required)
            .field("kind", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIToken.schema).delete()
    }
}
