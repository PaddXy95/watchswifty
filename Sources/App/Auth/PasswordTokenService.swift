import Fluent
import Foundation
import Vapor

/// Why a password link cannot be used.
enum PasswordLinkProblem: Error, Equatable {
    case invalid
    case expiredInvite

    var message: String {
        switch self {
        case .invalid: "Der Link ist ungültig oder abgelaufen. Fordere unter „Passwort vergessen“ einen neuen an."
        case .expiredInvite: "Die Einladung ist abgelaufen – bitte wende dich an deinen Admin."
        }
    }
}

/// Issues and redeems one-time links for setting a password (reset and invitation).
struct PasswordTokenService {
    let db: any Database

    /// A new token (32 random bytes, Base64URL); replaces older tokens of the same user and purpose.
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
    func lookup(_ token: String) async throws -> PasswordToken? {
        guard !token.isEmpty, token.count <= 128 else { return nil }
        return try await PasswordToken.query(on: db).filter(\.$tokenHash == APITokenService.hash(token)).first()
    }

    /// The usable token, or why it cannot be used.
    func check(_ token: String, now: Date = .now) async throws -> Result<PasswordToken, PasswordLinkProblem> {
        guard let record = try await lookup(token) else { return .failure(.invalid) }
        guard record.expiresAt > now else { return .failure(record.tokenPurpose == .invite ? .expiredInvite : .invalid) }
        return .success(record)
    }

    /// Sets the password and ends every link of the user. Throws `PasswordLinkProblem` or `APIError.validation`.
    func setPassword(token: String, password: String, hasher: AsyncPasswordHasher, now: Date = .now) async throws -> (User, PasswordTokenPurpose) {
        let record = try await check(token, now: now).get()
        guard let user = try await User.find(record.$user.id, on: db) else { throw PasswordLinkProblem.invalid }
        if let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(password)
        try await user.save(on: db)
        try await deleteAll(userID: user.requireID())
        return (user, record.tokenPurpose)
    }

    func latest(userID: UUID, purpose: PasswordTokenPurpose) async throws -> PasswordToken? {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).filter(\.$purpose == purpose.rawValue)
            .sort(\.$createdAt, .descending).first()
    }

    func deleteAll(userID: UUID) async throws {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).delete()
    }

    func deleteReset(userID: UUID) async throws {
        try await PasswordToken.query(on: db).filter(\.$user.$id == userID).filter(\.$purpose == PasswordTokenPurpose.reset.rawValue).delete()
    }

    @discardableResult
    func deleteExpired(now: Date = .now) async throws -> Int {
        let expired = PasswordToken.query(on: db).filter(\.$expiresAt <= now)
        let count = try await expired.count()
        try await PasswordToken.query(on: db).filter(\.$expiresAt <= now).delete()
        return count
    }
}
