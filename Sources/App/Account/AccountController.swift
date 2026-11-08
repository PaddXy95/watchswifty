import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    struct TokenInput: Content { var token: String }
    struct DeviceInput: Content { var name: String }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
        protected.post("account", "tmdb-token", use: saveToken)
        protected.post("account", "tmdb-token", "remove", use: removeToken)
        protected.post("account", "devices", use: createDeviceToken)
        protected.post("account", "devices", ":deviceID", "revoke", use: revokeDevice)
    }

    /// Token for scripts or trying out the API docs; shown only in this response.
    func createDeviceToken(req: Request) async throws -> HTMLResponse {
        let name = try req.content.decode(DeviceInput.self).name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else {
            return try await page(req, status: .unprocessableEntity, error: "Der Name muss 1 bis 60 Zeichen haben.")
        }
        let issued = try await APITokenService(db: req.db).issue(userID: try req.userID, name: name, kind: .manual)
        return try await page(req, newToken: issued.token)
    }

    func revokeDevice(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("deviceID", as: UUID.self) else { throw Abort(.notFound) }
        try await APITokenService(db: req.db).revoke(id: id, userID: try req.userID)
        return try await page(req, notice: "Gerät abgemeldet.")
    }

    func show(req: Request) async throws -> HTMLResponse {
        try await page(req)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        let input = try req.content.decode(ChangeInput.self)
        guard try await req.password.async.verify(input.currentPassword, created: user.passwordHash) else {
            return try await page(req, status: .unprocessableEntity, error: AccountValidation.wrongCurrentPasswordMessage)
        }
        if let error = AccountValidation.passwordError(input.newPassword) {
            return try await page(req, status: .unprocessableEntity, error: error)
        }
        user.passwordHash = try await req.password.async.hash(input.newPassword)
        try await user.save(on: req.db)
        return try await page(req, notice: "Passwort geändert.")
    }

    /// Stores the user's TMDB token after TMDB accepted it.
    func saveToken(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        let token = try req.content.decode(TokenInput.self).token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return try await page(req, status: .unprocessableEntity, error: "Bitte einen Token eingeben.") }
        do {
            try await req.application.tmdbProvider.make(token).validate()
        } catch TMDBError.unauthorized {
            return try await page(req, status: .unprocessableEntity, error: "TMDB hat den Token abgelehnt.")
        } catch {
            return try await page(req, status: .unprocessableEntity, error: "TMDB nicht erreichbar – Token nicht gespeichert.")
        }
        user.tmdbToken = try req.application.tokenCipher.seal(token)
        try await user.save(on: req.db)
        await req.application.matchingWorker.kick()
        return try await page(req, notice: "TMDB-Token gespeichert.")
    }

    func removeToken(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        user.tmdbToken = nil
        try await user.save(on: req.db)
        return try await page(req, notice: "TMDB-Token entfernt.")
    }

    private func page(_ req: Request, status: HTTPStatus = .ok, error: String? = nil, notice: String? = nil,
                      newToken: String? = nil) async throws -> HTMLResponse {
        let stored = try req.currentUser.tmdbToken
        let suffix = req.tmdbToken.map { "…" + String($0.suffix(4)) }
        let unreadable = suffix == nil && !(stored ?? "").isEmpty
        let followed = try await NewEpisodesService(db: req.db).followedSeries(userID: try req.userID, today: req.watches.today())
        let devices = try await APITokenService(db: req.db).list(userID: try req.userID)
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice,
                                                        followed: followed, tokenUnreadable: unreadable, devices: devices,
                                                        newToken: newToken))
    }
}
