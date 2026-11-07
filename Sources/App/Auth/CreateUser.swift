import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("username", .string, .required)
            .field("password_hash", .string, .required)
            .field("is_admin", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "username")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
