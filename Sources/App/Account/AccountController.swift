import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
    }

    func show(req: Request) async throws -> HTMLResponse {
        HTMLResponse(AccountPage(nav: try req.nav(.account), error: nil, notice: nil))
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        let input = try req.content.decode(ChangeInput.self)
        guard try await req.password.async.verify(input.currentPassword, created: user.passwordHash) else {
            return HTMLResponse(status: .unprocessableEntity,
                                AccountPage(nav: try req.nav(.account), error: AccountValidation.wrongCurrentPasswordMessage, notice: nil))
        }
        if let error = AccountValidation.passwordError(input.newPassword) {
            return HTMLResponse(status: .unprocessableEntity, AccountPage(nav: try req.nav(.account), error: error, notice: nil))
        }
        user.passwordHash = try await req.password.async.hash(input.newPassword)
        try await user.save(on: req.db)
        return HTMLResponse(AccountPage(nav: try req.nav(.account), error: nil, notice: "Passwort geändert."))
    }
}
