import Fluent
import Foundation
import Vapor

/// A WatchSwifty account (`users`): username, password hash, admin flag and the per-user settings.
final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "username") var username: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "is_admin") var isAdmin: Bool
    /// The user's own TMDB read access token (secret; never rendered or logged).
    @OptionalField(key: "tmdb_token") var tmdbToken: String?
    /// The user's own e-mail address, sealed with the server key (admins only ever see a mask).
    @OptionalField(key: "email") var email: String?
    /// OpenID Connect identity: the provider's issuer (as its discovery states it) and the subject.
    @OptionalField(key: "oidc_issuer") var oidcIssuer: String?
    @OptionalField(key: "oidc_subject") var oidcSubject: String?
    /// Preferred way for notifications (`NotifyChannel`); nil = mail.
    @OptionalField(key: "notify_channel") var notifyChannel: String?
    /// Notices for followed series: newly announced episode, 1–3 days before, on the air date (nil = off).
    @OptionalField(key: "notify_announced") var notifyAnnounced: Bool?
    @OptionalField(key: "notify_soon") var notifySoon: Bool?
    @OptionalField(key: "notify_today") var notifyToday: Bool?
    /// When „neu angekündigt“ was last switched on: only episodes first seen later count.
    @OptionalField(key: "notify_announced_since") var notifyAnnouncedSince: Date?
    /// Country for streaming availability (ISO 3166-1, e.g. „DE“); nil = `DE`.
    @OptionalField(key: "watch_region") var watchRegion: String?
    /// Notify when a title on „Später ansehen“ becomes available at one of the user's services; nil = off.
    @OptionalField(key: "notify_available") var notifyAvailable: Bool?

    /// The user's country for streaming availability.
    var region: String { watchRegion ?? "DE" }
    /// The user's KNot API key, sealed with the server key (never rendered or logged).
    @OptionalField(key: "webhook_key") var webhookKey: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates an account.
    /// - Parameters:
    ///   - id: The ID, or `nil` to have one generated on save.
    ///   - username: The normalized username (see `normalize(_:)`).
    ///   - passwordHash: The password hash, or `noPasswordHash` for an account without password.
    ///   - isAdmin: Whether the account is an admin.
    init(id: UUID? = nil, username: String, passwordHash: String, isAdmin: Bool) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.isAdmin = isAdmin
    }

    /// Stored for accounts without a password (pending invitation); never matches any password.
    static let noPasswordHash = "!"

    /// Whether the account has a password; `false` for pending invitations and accounts created through OIDC.
    var hasPassword: Bool { passwordHash != Self.noPasswordHash }

    /// Usernames are stored trimmed and lowercased; login is case-insensitive.
    /// - Parameter username: The username as entered.
    /// - Returns: The trimmed, lowercased username.
    static func normalize(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension User: ModelSessionAuthenticatable {}

extension User {
    /// Linked with the configured provider; a link to another (old) issuer does not count, nor does any link while
    /// OIDC is not configured.
    /// - Parameter oidc: The provider in effect, or `nil` without OIDC.
    /// - Returns: `true` when the stored subject is set and the stored issuer matches the provider's.
    func isLinked(_ oidc: OIDCConfig?) -> Bool {
        guard let oidc, let subject = oidcSubject, !subject.isEmpty else { return false }
        return oidc.matchesIssuer(oidcIssuer)
    }

    /// Linked and without a usable password login: such accounts go through the provider when connecting an app.
    /// - Parameters:
    ///   - oidc: The provider in effect, or `nil` without OIDC.
    ///   - passwordLogin: Whether the password login is on.
    /// - Returns: `true` when linked and the account has no password or the password login is off.
    func isSSOAccount(_ oidc: OIDCConfig?, passwordLogin: Bool) -> Bool {
        isLinked(oidc) && !(hasPassword && passwordLogin)
    }

    /// Linked accounts without password take their address from the provider (they never get reset mails).
    /// - Parameter oidc: The provider in effect, or `nil` without OIDC.
    /// - Returns: `true` for linked accounts without password.
    func emailFromProvider(_ oidc: OIDCConfig?) -> Bool {
        isLinked(oidc) && !hasPassword
    }
}

/// What a user's stored e-mail address amounts to.
enum EmailState: Equatable, Sendable {
    /// No address stored.
    case none
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    /// The decrypted address.
    case address(String)

    /// The address, when stored and readable.
    var address: String? {
        if case .address(let address) = self { return address }
        return nil
    }
}

extension User {
    /// Decrypts the stored e-mail address.
    /// - Parameter cipher: The server's token cipher.
    /// - Returns: `.none`, `.unreadable` or the address.
    func emailState(_ cipher: TokenCipher) -> EmailState {
        guard let stored = email, !stored.isEmpty else { return .none }
        return cipher.open(stored).map(EmailState.address) ?? .unreadable
    }
}

/// Adds `users.email` (the user's e-mail address, sealed with `TokenCipher`).
struct AddUserEmail: AsyncMigration {
    /// Adds the column.
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("email", .string).update()
    }

    /// Removes the column.
    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("email").update()
    }
}

extension Request {
    /// The signed-in user.
    /// - Throws: `Abort(.unauthorized)` when the request is not authenticated.
    var currentUser: User {
        get throws { try auth.require(User.self) }
    }

    /// The signed-in user's ID.
    /// - Throws: `Abort(.unauthorized)` when the request is not authenticated.
    var userID: UUID {
        get throws { try currentUser.requireID() }
    }
}

extension Request {
    /// The navigation context for a page of the signed-in user; admins also get the newer release found by the update
    /// check.
    /// - Parameter item: The highlighted navigation entry.
    /// - Returns: The context for `PageLayout`.
    /// - Throws: `Abort(.unauthorized)` when the request is not authenticated.
    func nav(_ item: NavItem) throws -> NavContext {
        let user = try currentUser
        return NavContext(username: user.username, isAdmin: user.isAdmin, active: item,
                          updateVersion: user.isAdmin ? application.updateStatus.newerVersion : nil)
    }
}
