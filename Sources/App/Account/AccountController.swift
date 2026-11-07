import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    struct TokenInput: Content { var token: String }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
        protected.post("account", "tmdb-token", use: saveToken)
        protected.post("account", "tmdb-token", "remove", use: removeToken)
    }

    func show(req: Request) async throws -> HTMLResponse {
        try page(req)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        let input = try req.content.decode(ChangeInput.self)
        guard try await req.password.async.verify(input.currentPassword, created: user.passwordHash) else {
            return try page(req, status: .unprocessableEntity, error: AccountValidation.wrongCurrentPasswordMessage)
        }
        if let error = AccountValidation.passwordError(input.newPassword) {
            return try page(req, status: .unprocessableEntity, error: error)
        }
        user.passwordHash = try await req.password.async.hash(input.newPassword)
        try await user.save(on: req.db)
        return try page(req, notice: "Passwort geändert.")
    }

    /// Stores the user's TMDB token after TMDB accepted it.
    func saveToken(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        let token = try req.content.decode(TokenInput.self).token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return try page(req, status: .unprocessableEntity, error: "Bitte einen Token eingeben.") }
        do {
            try await req.application.tmdbProvider.make(token).validate()
        } catch TMDBError.unauthorized {
            return try page(req, status: .unprocessableEntity, error: "TMDB hat den Token abgelehnt.")
        } catch {
            return try page(req, status: .unprocessableEntity, error: "TMDB nicht erreichbar – Token nicht gespeichert.")
        }
        user.tmdbToken = token
        try await user.save(on: req.db)
        await req.application.matchingWorker.kick()
        return try page(req, notice: "TMDB-Token gespeichert.")
    }

    func removeToken(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        user.tmdbToken = nil
        try await user.save(on: req.db)
        return try page(req, notice: "TMDB-Token entfernt.")
    }

    private func page(_ req: Request, status: HTTPStatus = .ok, error: String? = nil, notice: String? = nil) throws -> HTMLResponse {
        let token = try req.currentUser.tmdbToken
        let suffix = token.flatMap { $0.isEmpty ? nil : "…" + String($0.suffix(4)) }
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice))
    }
}
