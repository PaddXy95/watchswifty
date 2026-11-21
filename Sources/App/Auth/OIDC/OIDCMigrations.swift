import Fluent
import SQLKit

/// `users.oidc_issuer` + `users.oidc_subject`, unique as a pair. SQLite adds one column per `ALTER TABLE` and cannot
/// add constraints that way, so the uniqueness is a separate index.
struct AddUserOIDC: AsyncMigration {
    /// Adds both columns and, on SQL databases, the unique index `users_oidc_identity`.
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("oidc_issuer", .string).update()
        try await database.schema(User.schema).field("oidc_subject", .string).update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE UNIQUE INDEX users_oidc_identity ON users (oidc_issuer, oidc_subject)").run()
        }
    }

    /// Drops the index and both columns.
    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS users_oidc_identity").run()
        }
        try await database.schema(User.schema).deleteField("oidc_subject").update()
        try await database.schema(User.schema).deleteField("oidc_issuer").update()
    }
}

/// Creates `oidc_link_tokens` (unique token hash; rows are deleted with their user).
struct CreateOIDCLinkToken: AsyncMigration {
    /// Creates the table.
    func prepare(on database: any Database) async throws {
        try await database.schema(OIDCLinkToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(OIDCLinkToken.schema).delete()
    }
}
