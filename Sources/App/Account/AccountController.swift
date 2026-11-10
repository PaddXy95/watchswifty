import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    struct TokenInput: Content { var token: String }
    struct DeviceInput: Content { var name: String }
    struct EmailInput: Content { var email: String; var currentPassword: String }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
        protected.post("account", "email", use: setEmail)
        protected.post("account", "tmdb-token", use: saveToken)
        protected.post("account", "tmdb-token", "remove", use: removeToken)
        protected.post("account", "devices", use: createDeviceToken)
        protected.post("account", "devices", ":deviceID", "revoke", use: revokeDevice)
        protected.post("account", "oidc", "link", use: startLink)
    }

    /// „Mit … verknüpfen“: remembers the intent in the (signed-in) session and starts the provider flow on the
    /// canonical address.
    func startLink(req: Request) async throws -> Response {
        guard let oidc = req.application.appConfig.oidc else { throw Abort(.notFound) }
        guard isCanonical(req, oidc) else {
            return req.redirect(to: oidc.canonicalOrigin + "/account?sso=host", redirectType: .normal)
        }
        req.session.data[OIDCController.intentKey] = OIDCIntent.link.rawValue
        return req.redirect(to: "/auth/oidc/start", redirectType: .normal)
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
        let name = req.application.appConfig.oidc?.displayName ?? "SSO"
        switch try? req.query.get(String.self, at: "sso") {
        case "linked": return try await page(req, notice: "Mit \(name) verknüpft.")
        case "taken": return try await page(req, error: "Dieses \(name)-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.")
        case "host":
            let address = req.application.appConfig.oidc?.canonicalOrigin ?? ""
            return try await page(req, notice: "Verknüpfen geht nur über \(address) – dort erneut anmelden und klicken.")
        default: break
        }
        return try await page(req, notice: welcome ? "Willkommen – trag hier deinen TMDB-Token ein." : nil)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        guard req.application.appConfig.passwordLogin else { throw Abort(.notFound) }
        let input = try req.content.decode(ChangeInput.self)
        do {
            try await req.account.changePassword(user: try req.currentUser, current: input.currentPassword, new: input.newPassword)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message)
        }
        return try await page(req, notice: "Passwort geändert.")
    }

    func setEmail(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(EmailInput.self)
        do {
            try await req.account.setEmail(user: try req.currentUser, email: input.email, currentPassword: input.currentPassword)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message)
        }
        let removed = input.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return try await page(req, notice: removed ? "E-Mail-Adresse entfernt." : "E-Mail-Adresse gespeichert.")
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
        let mailConfigured = try await req.mailSettings.state().settings != nil
        let user = try req.currentUser
        let config = req.application.appConfig
        let sso = config.oidc.map { AccountSSO(name: $0.displayName, linked: user.isLinked($0), emailFromProvider: user.emailFromProvider($0)) }
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice,
                                                        followed: followed, tokenUnreadable: unreadable, devices: devices,
                                                        newToken: newToken, email: user.emailState(req.application.tokenCipher),
                                                        mailConfigured: mailConfigured, sso: sso,
                                                        passwordChange: user.hasPassword && config.passwordLogin))
    }
}
