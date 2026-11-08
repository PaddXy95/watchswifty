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
        do {
            _ = try await req.userAdmin.create(username: input.username, password: input.password, isAdmin: input.isAdmin ?? false)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func resetPassword(req: Request) async throws -> Response {
        let input = try req.content.decode(PasswordInput.self)
        do {
            try await req.userAdmin.resetPassword(id: try targetID(req), password: input.password, actingUserID: try req.userID)
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func setAdmin(req: Request) async throws -> Response {
        let makeAdmin = try req.content.decode(AdminInput.self).isAdmin ?? false
        do {
            try await req.userAdmin.setAdmin(id: try targetID(req), isAdmin: makeAdmin, actingUserID: try req.userID)
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func delete(req: Request) async throws -> HTMLResponse {
        do {
            try await req.userAdmin.delete(id: try targetID(req), actingUserID: try req.userID)
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message)
        }
        return try await page(req, status: .ok, notice: "Konto gelöscht.")
    }

    private func targetID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("userID", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    private func page(_ req: Request, status: HTTPStatus, error: String? = nil, notice: String? = nil) async throws -> HTMLResponse {
        let users = try await req.userAdmin.list()
        return HTMLResponse(status: status, AdminUsersPage(nav: try req.nav(.admin), users: users,
                                                           currentUserID: try req.userID, error: error, notice: notice))
    }
}
