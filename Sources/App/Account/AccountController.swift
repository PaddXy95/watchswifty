import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    struct TokenInput: Content { var token: String }
    struct DeviceInput: Content { var name: String }
    struct EmailInput: Content { var email: String; var currentPassword: String }
    struct LinkInput: Content { var currentPassword: String? }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
        protected.post("account", "email", use: setEmail)
        protected.post("account", "tmdb-token", use: saveToken)
        protected.post("account", "tmdb-token", "remove", use: removeToken)
        protected.post("account", "devices", use: createDeviceToken)
        protected.post("account", "devices", ":deviceID", "revoke", use: revokeDevice)
        protected.post("account", "oidc", "link", use: startLink)
        protected.post("account", "oidc", "reauth", use: startReauth)
    }

    /// „Über … bestätigen“: SSO accounts confirm through the provider before they get a manual token.
    func startReauth(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.oidc != nil else { throw Abort(.notFound) }
        req.session.data[OIDCController.intentKey] = OIDCIntent.reauth.rawValue
        req.session.data[OIDCController.returnToKey] = "/account"
        return req.redirect(to: "/auth/oidc/start", redirectType: .normal)
    }

    /// SSO accounts get no new API token without a fresh confirmation by the provider (spec „App verbinden“).
    private func tokenNeedsReauth(_ req: Request) throws -> Bool {
        let login = req.application.loginSettings.current
        return try req.currentUser.isSSOAccount(login.oidc, passwordLogin: login.passwordLogin)
            && !OIDCController.isFresh(verifiedAt: req.session.data[OIDCController.verifiedAtKey], now: .now)
    }

    /// „Mit … verknüpfen“: remembers the intent in the (signed-in) session and starts the provider flow on the
    /// canonical address.
    func startLink(req: Request) async throws -> Response {
        guard let oidc = req.application.loginSettings.current.oidc else { throw Abort(.notFound) }
        // Behind a proxy that rewrites Host, the browser's Origin still shows where it is.
        let browserOrigin = req.headers.first(name: .origin).map(OriginCheckMiddleware.normalizeOrigin)
        guard isCanonical(req, oidc) || browserOrigin == oidc.canonicalOrigin else {
            return req.redirect(to: oidc.canonicalOrigin + "/account?sso=host", redirectType: .normal)
        }
        let user = try req.currentUser
        if user.isLinked(oidc) {
            return try await page(req, status: .unprocessableEntity, error: OIDCLoginService.alreadyLinked(oidc).message).encodeResponse(for: req)
        }
        // Like the e-mail address: a hijacked session must not bind the account to someone else's identity.
        if user.hasPassword {
            let entered = (try? req.content.decode(LinkInput.self).currentPassword) ?? ""
            guard try await req.password.async.verify(entered, created: user.passwordHash) else {
                return try await page(req, status: .unprocessableEntity, error: AccountValidation.wrongCurrentPasswordMessage)
                    .encodeResponse(for: req)
            }
        }
        req.session.data[OIDCController.intentKey] = OIDCIntent.link.rawValue
        return req.redirect(to: "/auth/oidc/start", redirectType: .normal)
    }

    /// Token for scripts or trying out the API docs; shown only in this response.
    func createDeviceToken(req: Request) async throws -> HTMLResponse {
        if try tokenNeedsReauth(req) {
            let ssoName = req.application.loginSettings.current.oidc?.displayName ?? "SSO"
            return try await page(req, status: .forbidden, error: "Bitte zuerst über \(ssoName) bestätigen – danach das Token erstellen.")
        }
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
        let name = req.application.loginSettings.current.oidc?.displayName ?? "SSO"
        switch try? req.query.get(String.self, at: "sso") {
        case "linked": return try await page(req, notice: "Mit \(name) verknüpft.")
        case "taken": return try await page(req, error: "Dieses \(name)-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.")
        case "host":
            let address = req.application.loginSettings.current.oidc?.canonicalOrigin ?? ""
            return try await page(req, notice: "Verknüpfen geht nur über \(address) – dort erneut anmelden und klicken.")
        default: break
        }
        return try await page(req, notice: welcome ? "Willkommen – trag hier deinen TMDB-Token ein." : nil)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
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
        let config = req.application.loginSettings.current
        let sso = config.oidc.map { AccountSSO(name: $0.displayName, linked: user.isLinked($0), emailFromProvider: user.emailFromProvider($0),
                                               needsPassword: user.hasPassword) }
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice,
                                                        followed: followed, tokenUnreadable: unreadable, devices: devices,
                                                        newToken: newToken, email: user.emailState(req.application.tokenCipher),
                                                        mailConfigured: mailConfigured, sso: sso,
                                                        passwordChange: user.hasPassword && config.passwordLogin,
                                                        tokenNeedsReauth: try tokenNeedsReauth(req)))
    }
}
