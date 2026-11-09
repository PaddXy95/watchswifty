import Fluent
import Foundation
import Vapor

enum InviteState: Equatable, Sendable {
    /// The account has a password.
    case none
    case pending(expires: Date)
    case expired
}

/// A user as admins see them: the address only as a mask.
struct AdminUserRow: Sendable {
    let user: User
    let emailHint: String?
    let invite: InviteState
}

/// User administration shared by the „Benutzer“ page and `/v1/admin/users`. Admins never act on their own account
/// here (password via Konto), so a stolen admin device cannot lock the owner out.
struct UserAdminService {
    static let neitherMessage = "Bitte ein Startpasswort oder eine E-Mail-Adresse für die Einladung angeben."
    static let inviteNeedsMailMessage = "Einladungen gehen erst, wenn der Mail-Versand unter System eingerichtet ist."
    static let hasPasswordMessage = "Das Konto hat schon ein Passwort."
    static let noAddressMessage = "Für dieses Konto ist keine lesbare E-Mail-Adresse hinterlegt."

    let db: any Database
    let hasher: AsyncPasswordHasher
    let cipher: TokenCipher
    let mail: MailService

    func list() async throws -> [AdminUserRow] {
        var rows: [AdminUserRow] = []
        for user in try await User.query(on: db).sort(\.$username).all() {
            rows.append(try await row(for: user))
        }
        return rows
    }

    func row(for user: User, now: Date = .now) async throws -> AdminUserRow {
        var invite = InviteState.none
        if !user.hasPassword {
            let token = try await PasswordTokenService(db: db).latest(userID: user.requireID(), purpose: .invite)
            invite = token.map { $0.expiresAt > now ? .pending(expires: $0.expiresAt) : .expired } ?? .expired
        }
        return AdminUserRow(user: user, emailHint: user.emailState(cipher).address.map(EmailAddress.mask), invite: invite)
    }

    /// With a password: a normal account (an address is only stored). Without one but with an address: an account
    /// without password plus an invitation mail. A failed mail keeps the account and returns the reason.
    func create(username rawUsername: String, password rawPassword: String?, email rawEmail: String?, isAdmin: Bool,
                inviter: User) async throws -> (user: User, inviteMailError: String?) {
        let username = User.normalize(rawUsername)
        if let error = AccountValidation.usernameError(username) { throw APIError.validation(error) }
        let password = rawPassword.flatMap { $0.isEmpty ? nil : $0 }
        if let password, let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        var address: String?
        if let raw = rawEmail, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = EmailAddress.normalize(raw) else { throw APIError.validation(EmailAddress.invalidMessage) }
            address = normalized
        }
        guard password != nil || address != nil else { throw APIError.validation(Self.neitherMessage) }
        if try await User.query(on: db).filter(\.$username == username).first() != nil {
            throw APIError.validation(AccountValidation.duplicateMessage)
        }
        var settings: MailSettings?
        if password == nil {
            settings = try await mail.settings.state().settings
            guard settings != nil else { throw APIError.mailNotConfigured(Self.inviteNeedsMailMessage) }
        }

        var hash = User.noPasswordHash
        if let password { hash = try await hasher.hash(password) }
        let user = User(username: username, passwordHash: hash, isAdmin: isAdmin)
        user.email = try address.map { try cipher.seal($0) }
        try await user.save(on: db)

        guard let settings, let address else { return (user, nil) }
        do {
            try await sendInvite(user: user, address: address, inviter: inviter, settings: settings)
            return (user, nil)
        } catch let error as MailError {
            return (user, error.message)
        }
    }

    /// New invitation link (the old one stops working). Throws `MailError` when the mail fails.
    @discardableResult
    func resendInvite(id: UUID, inviter: User) async throws -> User {
        let user = try await target(id)
        guard !user.hasPassword else { throw APIError.validation(Self.hasPasswordMessage) }
        guard let settings = try await mail.settings.state().settings else { throw APIError.mailNotConfigured(Self.inviteNeedsMailMessage) }
        guard let address = user.emailState(cipher).address else { throw APIError.validation(Self.noAddressMessage) }
        try await sendInvite(user: user, address: address, inviter: inviter, settings: settings)
        return user
    }

    private func sendInvite(user: User, address: String, inviter: User, settings: MailSettings, now: Date = .now) async throws {
        let token = try await PasswordTokenService(db: db).issue(userID: user.requireID(), purpose: .invite, now: now)
        try await mail.send(MailTexts.invite(to: address, username: user.username, inviter: inviter.username,
                                             link: settings.link(token: token),
                                             expires: now.addingTimeInterval(PasswordTokenPurpose.invite.lifetime)), now: now)
    }

    /// Also ends an open invitation or reset link.
    func resetPassword(id: UUID, password: String, actingUserID: UUID) async throws {
        guard id != actingUserID else { throw APIError.selfAction }
        let user = try await target(id)
        if let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(password)
        try await user.save(on: db)
        try await PasswordTokenService(db: db).deleteAll(userID: id)
    }

    @discardableResult
    func setAdmin(id: UUID, isAdmin: Bool, actingUserID: UUID) async throws -> User {
        let user = try await target(id)
        if !isAdmin, user.isAdmin, try await adminCount() <= 1 { throw APIError.validation(AccountValidation.lastAdminMessage) }
        guard id != actingUserID else { throw APIError.selfAction }
        user.isAdmin = isAdmin
        try await user.save(on: db)
        return user
    }

    func delete(id: UUID, actingUserID: UUID) async throws {
        guard id != actingUserID else {
            throw APIError(status: .unprocessableEntity, code: "selfAction", message: AccountValidation.selfDeleteMessage)
        }
        let user = try await target(id)
        if user.isAdmin, try await adminCount() <= 1 { throw APIError.validation(AccountValidation.lastAdminMessage) }
        try await user.delete(on: db)
    }

    private func target(_ id: UUID) async throws -> User {
        guard let user = try await User.find(id, on: db) else { throw APIError.notFound }
        return user
    }

    private func adminCount() async throws -> Int {
        try await User.query(on: db).filter(\.$isAdmin == true).count()
    }
}

extension Application {
    var userAdmin: UserAdminService {
        UserAdminService(db: db, hasher: password.async, cipher: tokenCipher, mail: mail)
    }
}

extension Request {
    var userAdmin: UserAdminService {
        UserAdminService(db: db, hasher: password.async, cipher: application.tokenCipher, mail: mail)
    }
}
