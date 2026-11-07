import Fluent

struct AddUserTMDBToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("tmdb_token", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("tmdb_token").update()
    }
}
