import Fluent
import Foundation
import Vapor

/// Why a password link cannot be used.
enum PasswordLinkProblem: Error, Equatable {
    /// Unknown token, expired reset link, or a token that does not fit the use.
    case invalid
    /// An invitation whose seven days have passed.
    case expiredInvite

    /// The German message shown on the reset page.
    var message: String {
        switch self {
        case .invalid: "Der Link ist ungültig oder abgelaufen. Fordere unter „Passwort vergessen“ einen neuen an – bei einer Einladung wende dich an deinen Admin."
        case .expiredInvite: "Die Einladung ist abgelaufen – bitte wende dich an deinen Admin."
        }
    }
}

/// Issues and redeems one-time links for setting a password (reset and invitation).
struct PasswordTokenService {
    let db: any Database

    /// A new token (32 random bytes, Base64URL); replaces older tokens of the same user and purpose.
    /// - Parameters:
    ///   - userID: The account the link is for.
    ///   - purpose: Reset or invitation; decides the lifetime.
    ///   - now: The creation time.
    /// - Returns: The plain token for the link; only its SHA-256 hash is stored.
    /// - Throws: Database errors.
    func issue(userID: UUID, purpose: PasswordTokenPurpose, now: Date = .now) async throws -> String {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).filter(\.$purpose == purpose.rawValue).delete()
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try await PasswordToken(userID: userID, purpose: purpose, tokenHash: APITokenService.hash(token), createdAt: now).save(on: db)
        return token
    }

    /// The stored token, also when it has expired (callers compare `expiresAt`).
    /// - Parameter token: The token from the link; empty values and values over 128 characters are ignored.
    /// - Returns: The matching record, or `nil`.
    /// - Throws: Database errors.
    func lookup(_ token: String) async throws -> PasswordToken? {
        guard !token.isEmpty, token.count <= 128 else { return nil }
        return try await PasswordToken.query(on: db).filter(\.$tokenHash == APITokenService.hash(token)).first()
    }

    /// The usable token, or why it cannot be used.
    /// - Parameters:
    ///   - token: The token from the link.
    ///   - now: The time to check the expiry against.
    /// - Returns: The record, or `.invalid` / `.expiredInvite` (expired invitations get their own message).
    /// - Throws: Database errors.
    func check(_ token: String, now: Date = .now) async throws -> Result<PasswordToken, PasswordLinkProblem> {
        guard let record = try await lookup(token) else { return .failure(.invalid) }
        guard record.expiresAt > now else { return .failure(record.tokenPurpose == .invite ? .expiredInvite : .invalid) }
        return .success(record)
    }

    /// Sets the password and ends every link of the user. Throws `PasswordLinkProblem` or `APIError.validation`.
    /// - Parameters:
    ///   - token: The token from the link.
    ///   - password: The new password.
    ///   - hasher: Hashes the password.
    ///   - now: The time to check the expiry against.
    /// - Returns: The user and the purpose of the used link.
    func setPassword(token: String, password: String, hasher: AsyncPasswordHasher, now: Date = .now) async throws -> (User, PasswordTokenPurpose) {
        let record = try await check(token, now: now).get()
        guard let user = try await User.find(record.$user.id, on: db) else { throw PasswordLinkProblem.invalid }
        if let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(password)
        try await user.save(on: db)
        try await deleteAll(userID: user.requireID())
        return (user, record.tokenPurpose)
    }

    /// The newest token of a user and purpose, also when expired (used for the reset-mail throttle).
    /// - Parameters:
    ///   - userID: The account.
    ///   - purpose: Reset or invitation.
    /// - Returns: The newest record, or `nil`.
    /// - Throws: Database errors.
    func latest(userID: UUID, purpose: PasswordTokenPurpose) async throws -> PasswordToken? {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).filter(\.$purpose == purpose.rawValue)
            .sort(\.$createdAt, .descending).first()
    }

    /// Ends every password link (reset and invitation) of a user.
    /// - Parameter userID: The account.
    /// - Throws: Database errors.
    func deleteAll(userID: UUID) async throws {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).delete()
    }

    /// Ends the user's reset links; invitations stay.
    /// - Parameter userID: The account.
    /// - Throws: Database errors.
    func deleteReset(userID: UUID) async throws {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).filter(\.$purpose == PasswordTokenPurpose.reset.rawValue).delete()
    }

    /// Removes expired reset links. Expired invitations stay (at most one per account; they go when a password is
    /// set, the invitation is resent or the account is deleted), so their link can still point to the admin.
    /// - Parameter now: The reference time.
    /// - Returns: The number of deleted reset links.
    /// - Throws: Database errors.
    @discardableResult
    func deleteExpired(now: Date = .now) async throws -> Int {
        let reset = PasswordTokenPurpose.reset.rawValue
        let count = try await PasswordToken.query(on: db).filter(\.$purpose == reset).filter(\.$expiresAt <= now).count()
        try await PasswordToken.query(on: db).filter(\.$purpose == reset).filter(\.$expiresAt <= now).delete()
        return count
    }
}
