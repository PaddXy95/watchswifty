import Fluent
import Vapor

struct AdminUsersController {
    struct CreateInput: Content { var username: String; var password: String; var isAdmin: Bool? }
    struct PasswordInput: Content { var password: String }
    struct AdminInput: Content { var isAdmin: Bool? }

    func register(on protected: any RoutesBuilder) {
        let admin = protected.grouped(RequireAdminMiddleware()).grouped("admin", "users")
        admin.get(use: list)
        admin.post(use: create)
        admin.post(":userID", "password", use: resetPassword)
        admin.post(":userID", "admin", use: setAdmin)
        admin.delete(":userID", use: delete)
    }

    func list(req: Request) async throws -> HTMLResponse {
        try await page(req, status: .ok)
    }

    func create(req: Request) async throws -> Response {
        let input = try req.content.decode(CreateInput.self)
        let username = User.normalize(input.username)
        if let error = AccountValidation.usernameError(username) ?? AccountValidation.passwordError(input.password) {
            return try await page(req, status: .unprocessableEntity, error: error).encodeResponse(for: req)
        }
        if try await User.query(on: req.db).filter(\.$username == username).first() != nil {
            return try await page(req, status: .unprocessableEntity, error: AccountValidation.duplicateMessage).encodeResponse(for: req)
        }
        let hash = try await req.password.async.hash(input.password)
        try await User(username: username, passwordHash: hash, isAdmin: input.isAdmin ?? false).save(on: req.db)
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func resetPassword(req: Request) async throws -> Response {
        let user = try await target(req)
        let input = try req.content.decode(PasswordInput.self)
        if let error = AccountValidation.passwordError(input.password) {
            return try await page(req, status: .unprocessableEntity, error: error).encodeResponse(for: req)
        }
        user.passwordHash = try await req.password.async.hash(input.password)
        try await user.save(on: req.db)
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func setAdmin(req: Request) async throws -> Response {
        let user = try await target(req)
        let makeAdmin = try req.content.decode(AdminInput.self).isAdmin ?? false
        if !makeAdmin, user.isAdmin, try await adminCount(req) <= 1 {
            return try await page(req, status: .unprocessableEntity, error: AccountValidation.lastAdminMessage).encodeResponse(for: req)
        }
        user.isAdmin = makeAdmin
        try await user.save(on: req.db)
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func delete(req: Request) async throws -> HTMLResponse {
        let user = try await target(req)
        if try user.requireID() == req.userID {
            return try await page(req, status: .unprocessableEntity, error: AccountValidation.selfDeleteMessage)
        }
        if user.isAdmin, try await adminCount(req) <= 1 {
            return try await page(req, status: .unprocessableEntity, error: AccountValidation.lastAdminMessage)
        }
        try await user.delete(on: req.db)
        return try await page(req, status: .ok, notice: "Konto gelöscht.")
    }

    private func target(_ req: Request) async throws -> User {
        guard let id = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db) else { throw Abort(.notFound) }
        return user
    }

    private func adminCount(_ req: Request) async throws -> Int {
        try await User.query(on: req.db).filter(\.$isAdmin == true).count()
    }

    private func page(_ req: Request, status: HTTPStatus, error: String? = nil, notice: String? = nil) async throws -> HTMLResponse {
        let users = try await User.query(on: req.db).sort(\.$username).all()
        return HTMLResponse(status: status, AdminUsersPage(nav: try req.nav(.admin), users: users,
                                                           currentUserID: try req.userID, error: error, notice: notice))
    }
}
