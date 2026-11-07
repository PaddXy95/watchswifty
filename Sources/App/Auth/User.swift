import Fluent
import Foundation
import Vapor

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "username") var username: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "is_admin") var isAdmin: Bool
    /// The user's own TMDB read access token (secret; never rendered or logged).
    @OptionalField(key: "tmdb_token") var tmdbToken: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, username: String, passwordHash: String, isAdmin: Bool) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.isAdmin = isAdmin
    }

    /// Usernames are stored trimmed and lowercased; login is case-insensitive.
    static func normalize(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension User: ModelSessionAuthenticatable {}

extension Request {
    var currentUser: User {
        get throws { try auth.require(User.self) }
    }

    var userID: UUID {
        get throws { try currentUser.requireID() }
    }
}

extension Request {
    func nav(_ item: NavItem) throws -> NavContext {
        let user = try currentUser
        return NavContext(username: user.username, isAdmin: user.isAdmin, active: item)
    }
}
