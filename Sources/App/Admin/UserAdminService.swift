import Fluent
import Foundation
import Vapor

/// Invitation status of an account as shown in the user list.
enum InviteState: Equatable, Sendable {
    /// The account has a password.
    case none
    /// Without password, with a valid invitation link that expires at `expires`.
    case pending(expires: Date)
    /// Without password and without a valid invitation link.
    case expired
}

/// A user as admins see them: the address only as a mask.
struct AdminUserRow: Sendable {
    /// The account.
    let user: User
    /// Masked e-mail address (see `EmailAddress.mask`), nil when none is readable.
    let emailHint: String?
    /// Invitation status of the account.
    let invite: InviteState
    /// Linked with the configured OIDC provider.
    var ssoLinked = false
}

/// Result of „Verknüpfungslink“: mailed, or the link to pass on (shown once).
struct SSOLinkResult: Equatable, Sendable {
    /// Whether the link was sent by mail.
    let mailed: Bool
    /// Masked address the mail went (or should have gone) to.
    let emailHint: String?
    /// The link to pass on, when it was not mailed.
    let url: String?
    /// German reason why sending the mail failed, if it did.
    let mailError: String?
}

/// User administration shared by the „Benutzer“ page and `/v1/admin/users`. Admins never act on their own account
/// here (password via Konto), so a stolen admin device cannot lock the owner out; granting admin rights and taking
/// over another admin's sign-in need an `AdminConfirmation`, so it cannot do so through a peer admin either.
struct UserAdminService {
    /// Error text when a new account gets neither a start password nor an invitation address.
    static let neitherMessage = "Bitte ein Startpasswort oder eine E-Mail-Adresse für die Einladung angeben."
    /// Error text when an invitation is requested but mail is not set up.
    static let inviteNeedsMailMessage = "Einladungen gehen erst, wenn der Mail-Versand unter Admin → System eingerichtet ist."
    /// Error text when inviting an account that already has a password.
    static let hasPasswordMessage = "Das Konto hat schon ein Passwort."
    /// Error text when an account has no readable e-mail address to invite.
    static let noAddressMessage = "Für dieses Konto ist keine lesbare E-Mail-Adresse hinterlegt."

    let db: any Database
    let hasher: AsyncPasswordHasher
    /// Cipher for the users' e-mail addresses, sealed at rest.
    let cipher: TokenCipher
    let mail: MailService
    /// The configured OIDC provider, nil when SSO is not set up.
    var oidc: OIDCConfig? = nil
    /// Whether password login is enabled.
    var passwordLogin = true

    /// Lists all accounts sorted by username.
    /// - Returns: One row per user with masked address and invitation status.
    /// - Throws: Database errors.
    func list() async throws -> [AdminUserRow] {
        var rows: [AdminUserRow] = []
        for user in try await User.query(on: db).sort(\.$username).all() {
            rows.append(try await row(for: user))
        }
        return rows
    }

    /// Builds the admin view of one account.
    ///
    /// Accounts without password that are not linked with the provider get their invitation status from the latest
    /// invitation token.
    /// - Parameters:
    ///   - user: The account.
    ///   - now: Reference time for the invitation expiry.
    /// - Returns: The row with masked address, invitation status and SSO link state.
    /// - Throws: Database errors.
    func row(for user: User, now: Date = .now) async throws -> AdminUserRow {
        var invite = InviteState.none
        if !user.hasPassword, !user.isLinked(oidc) {
            let token = try await PasswordTokenService(db: db).latest(userID: user.requireID(), purpose: .invite)
            invite = token.map { $0.expiresAt > now ? .pending(expires: $0.expiresAt) : .expired } ?? .expired
        }
        return AdminUserRow(user: user, emailHint: user.emailState(cipher).address.map(EmailAddress.mask), invite: invite,
                            ssoLinked: user.isLinked(oidc))
    }

    /// „Verknüpfungslink“ for another, not yet linked account: mailed when possible, else returned to show once.
    /// Linking another admin's account needs an `AdminConfirmation`.
    /// - Parameters:
    ///   - id: The account to link.
    ///   - inviter: The admin creating the link.
    ///   - confirmation: Proof of presence, checked when the target is an admin.
    /// - Returns: Whether the link was mailed, otherwise the link itself and any mail error.
    /// - Throws: `APIError.notFound` when SSO is not set up or the user is unknown, `APIError.selfAction` for the own
    ///   account, `APIError.validation` when already linked, a confirmation error from `requireConfirmation(by:_:)`.
    func createSSOLink(id: UUID, inviter: User, confirmation: AdminConfirmation) async throws -> SSOLinkResult {
        guard let oidc else { throw APIError.notFound }
        guard id != inviter.id else { throw APIError.selfAction }
        let user = try await target(id)
        guard !user.isLinked(oidc) else { throw APIError.validation("Das Konto ist schon mit \(oidc.displayName) verknüpft.") }
        if user.isAdmin { try await requireConfirmation(by: inviter, confirmation) }
        let now = Date.now
        let token = try await OIDCLinkTokenService(db: db).issue(userID: try user.requireID(), lifetime: OIDCLinkTokenService.adminLifetime,
                                                                 now: now)
        let url = oidc.canonicalOrigin + "/auth/oidc/start?link=" + token
        guard let address = user.emailState(cipher).address, try await mail.settings.state().settings != nil else {
            return SSOLinkResult(mailed: false, emailHint: nil, url: url, mailError: nil)
        }
        do {
            try await mail.send(MailTexts.ssoLink(to: address, username: user.username, inviter: inviter.username, ssoName: oidc.displayName,
                                                  link: url, expires: now.addingTimeInterval(OIDCLinkTokenService.adminLifetime)), now: now)
            return SSOLinkResult(mailed: true, emailHint: EmailAddress.mask(address), url: nil, mailError: nil)
        } catch let error as MailError {
            return SSOLinkResult(mailed: false, emailHint: EmailAddress.mask(address), url: url, mailError: error.message)
        }
    }

    /// With a password: a normal account (an address is only stored). Without one but with an address: an account
    /// without password plus an invitation mail. A failed mail keeps the account and returns the reason.
    /// - Parameters:
    ///   - rawUsername: Username as entered (normalized here).
    ///   - rawPassword: Start password; empty means none.
    ///   - rawEmail: E-mail address; required without a password, sealed with `TokenCipher` when stored.
    ///   - isAdmin: Whether the account gets admin rights (needs an `AdminConfirmation`).
    ///   - inviter: The admin creating the account.
    ///   - confirmation: Proof of presence, checked when `isAdmin` is set.
    /// - Returns: The new user and, if the invitation mail failed, the German reason.
    /// - Throws: `APIError.validation` for invalid or duplicate input, `APIError.passwordLoginDisabled` for a start
    ///   password while password login is off, `APIError.mailNotConfigured` for an invitation without mail set up, a
    ///   confirmation error from `requireConfirmation(by:_:)` when `isAdmin` is set.
    func create(username rawUsername: String, password rawPassword: String?, email rawEmail: String?, isAdmin: Bool,
                inviter: User, confirmation: AdminConfirmation) async throws -> (user: User, inviteMailError: String?) {
        if isAdmin { try await requireConfirmation(by: inviter, confirmation) }
        let username = User.normalize(rawUsername)
        if let error = AccountValidation.usernameError(username) { throw APIError.validation(error) }
        let password = rawPassword.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil, !passwordLogin {
            throw APIError.passwordLoginDisabled("Der Passwort-Login ist abgeschaltet – nur Einladungen.")
        }
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
    /// - Parameters:
    ///   - id: The account without password to invite again.
    ///   - inviter: The admin sending the invitation.
    /// - Returns: The invited user.
    /// - Throws: `MailError` when sending fails; `APIError.validation` when the account has a password, is linked with
    ///   the provider or has no readable address; `APIError.mailNotConfigured` without mail settings; `APIError.notFound`.
    @discardableResult
    func resendInvite(id: UUID, inviter: User) async throws -> User {
        let user = try await target(id)
        guard !user.hasPassword else { throw APIError.validation(Self.hasPasswordMessage) }
        if let oidc, user.isLinked(oidc) {
            throw APIError.validation("Das Konto ist mit \(oidc.displayName) verknüpft – keine Einladung nötig.")
        }
        guard let settings = try await mail.settings.state().settings else { throw APIError.mailNotConfigured(Self.inviteNeedsMailMessage) }
        guard let address = user.emailState(cipher).address else { throw APIError.validation(Self.noAddressMessage) }
        try await sendInvite(user: user, address: address, inviter: inviter, settings: settings)
        return user
    }

    /// Issues a new invitation token and mails the invitation link.
    /// - Parameters:
    ///   - user: The invited account.
    ///   - address: Plain e-mail address to send to.
    ///   - inviter: The admin sending the invitation (named in the mail).
    ///   - settings: Mail settings providing the public link origin.
    ///   - now: Issue time of the token.
    /// - Throws: `MailError` when sending fails; database errors.
    private func sendInvite(user: User, address: String, inviter: User, settings: MailSettings, now: Date = .now) async throws {
        let token = try await PasswordTokenService(db: db).issue(userID: user.requireID(), purpose: .invite, now: now)
        try await mail.send(MailTexts.invite(to: address, username: user.username, inviter: inviter.username,
                                             link: settings.link(token: token),
                                             expires: now.addingTimeInterval(PasswordTokenPurpose.invite.lifetime),
                                             ssoName: oidc?.displayName, passwordLogin: passwordLogin), now: now)
    }

    /// Sets another account's password as an admin.
    ///
    /// Also ends an open invitation or reset link.
    /// - Parameters:
    ///   - id: The account whose password to set.
    ///   - password: The new password (validated with `AccountValidation`).
    ///   - actingUserID: The admin performing the change.
    ///   - confirmation: Proof of presence, checked when the target is an admin.
    /// - Throws: `APIError.passwordLoginDisabled` when password login is off, `APIError.selfAction` for the own account,
    ///   `APIError.notFound`, `APIError.validation` for a weak password, a confirmation error.
    func resetPassword(id: UUID, password: String, actingUserID: UUID, confirmation: AdminConfirmation) async throws {
        guard passwordLogin else { throw APIError.passwordLoginDisabled() }
        guard id != actingUserID else { throw APIError.selfAction }
        let user = try await target(id)
        if user.isAdmin { try await requireConfirmation(by: try await target(actingUserID), confirmation) }
        if let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(password)
        try await user.save(on: db)
        try await PasswordTokenService(db: db).deleteAll(userID: id)
    }

    /// Grants or revokes admin rights for another account.
    ///
    /// Granting needs an `AdminConfirmation`; the last admin cannot be demoted.
    /// - Parameters:
    ///   - id: The target account.
    ///   - isAdmin: The new admin flag.
    ///   - actingUserID: The admin performing the change.
    ///   - confirmation: Proof of presence, checked when granting.
    /// - Returns: The updated user.
    /// - Throws: `APIError.notFound` for an unknown ID, `APIError.validation` for the last admin, `APIError.selfAction`
    ///   for the own account, a confirmation error from `requireConfirmation(by:_:)`.
    @discardableResult
    func setAdmin(id: UUID, isAdmin: Bool, actingUserID: UUID, confirmation: AdminConfirmation) async throws -> User {
        let user = try await target(id)
        if !isAdmin, user.isAdmin, try await adminCount() <= 1 { throw APIError.validation(AccountValidation.lastAdminMessage) }
        guard id != actingUserID else { throw APIError.selfAction }
        if isAdmin, !user.isAdmin { try await requireConfirmation(by: try await target(actingUserID), confirmation) }
        user.isAdmin = isAdmin
        try await user.save(on: db)
        return user
    }

    /// Deletes another account.
    /// - Parameters:
    ///   - id: The account to delete.
    ///   - actingUserID: The admin performing the deletion.
    /// - Throws: `selfAction` (422) for the own account, `APIError.notFound` for an unknown ID, `APIError.validation`
    ///   when it is the last admin.
    func delete(id: UUID, actingUserID: UUID) async throws {
        guard id != actingUserID else {
            throw APIError(status: .unprocessableEntity, code: "selfAction", message: AccountValidation.selfDeleteMessage)
        }
        let user = try await target(id)
        if user.isAdmin, try await adminCount() <= 1 { throw APIError.validation(AccountValidation.lastAdminMessage) }
        try await user.delete(on: db)
    }

    /// Loads the account an admin action targets.
    /// - Parameter id: The account's ID.
    /// - Returns: The user.
    /// - Throws: `APIError.notFound` when no such user exists.
    private func target(_ id: UUID) async throws -> User {
        guard let user = try await User.find(id, on: db) else { throw APIError.notFound }
        return user
    }

    /// Counts the admin accounts.
    /// - Returns: The number of users with admin rights.
    /// - Throws: Database errors.
    private func adminCount() async throws -> Int {
        try await User.query(on: db).filter(\.$isAdmin == true).count()
    }
}

extension Application {
    /// A user admin service for background code, using the current login settings.
    var userAdmin: UserAdminService {
        UserAdminService(db: db, hasher: password.async, cipher: tokenCipher, mail: mail, oidc: loginSettings.current.oidc,
                         passwordLogin: loginSettings.current.passwordLogin)
    }
}

extension Request {
    /// A user admin service for this request, using the current login settings.
    var userAdmin: UserAdminService {
        UserAdminService(db: db, hasher: password.async, cipher: application.tokenCipher, mail: mail,
                         oidc: application.loginSettings.current.oidc, passwordLogin: application.loginSettings.current.passwordLogin)
    }
}
