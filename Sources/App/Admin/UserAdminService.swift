import Fluent
import Foundation
import Vapor

/// User administration shared by the „Benutzer“ page and `/v1/admin/users`. Admins never act on their own account
/// here (password via Konto), so a stolen admin device cannot lock the owner out.
struct UserAdminService {
    let db: any Database
    let hasher: AsyncPasswordHasher

    func list() async throws -> [User] {
        try await User.query(on: db).sort(\.$username).all()
    }

    func create(username rawUsername: String, password: String, isAdmin: Bool) async throws -> User {
        let username = User.normalize(rawUsername)
        if let error = AccountValidation.usernameError(username) ?? AccountValidation.passwordError(password) {
            throw APIError.validation(error)
        }
        if try await User.query(on: db).filter(\.$username == username).first() != nil {
            throw APIError.validation(AccountValidation.duplicateMessage)
        }
        let user = User(username: username, passwordHash: try await hasher.hash(password), isAdmin: isAdmin)
        try await user.save(on: db)
        return user
    }

    func resetPassword(id: UUID, password: String, actingUserID: UUID) async throws {
        guard id != actingUserID else { throw APIError.selfAction }
        let user = try await target(id)
        if let error = AccountValidation.passwordError(password) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(password)
        try await user.save(on: db)
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

extension Request {
    var userAdmin: UserAdminService { UserAdminService(db: db, hasher: password.async) }
}
