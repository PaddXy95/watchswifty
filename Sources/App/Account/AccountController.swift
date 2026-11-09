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
        // After accepting an invitation (see PasswordResetController).
        let welcome = (try? req.query.get(String.self, at: "welcome")) == "1"
        return try await page(req, notice: welcome ? "Willkommen – trag hier deinen TMDB-Token ein." : nil)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(ChangeInput.self)
        do {
            try await req.account.changePassword(user: try req.currentUser, current: input.currentPassword, new: input.newPassword)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message)
        }
        return try await page(req, notice: "Passwort geändert.")
    }

    /// Stores the user's TMDB token after TMDB accepted it.
    func saveToken(req: Request) async throws -> HTMLResponse {
        let token = try req.content.decode(TokenInput.self).token
        do {
            try await req.account.saveTMDBToken(user: try req.currentUser, token: token)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message)
        }
        return try await page(req, notice: "TMDB-Token gespeichert.")
    }

    func removeToken(req: Request) async throws -> HTMLResponse {
        try await req.account.removeTMDBToken(user: try req.currentUser)
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
