import Fluent
import Vapor

struct AccountController {
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    struct TokenInput: Content { var token: String }
    struct DeviceInput: Content { var name: String }
    struct EmailInput: Content { var email: String; var currentPassword: String }
    struct LinkInput: Content { var currentPassword: String? }
    struct NotificationPrefsInput: Content { var announced: String?; var soon: String?; var today: String?; var channel: String? }
    struct WebhookKeyInput: Content { var key: String }

    func register(on protected: any RoutesBuilder) {
        protected.get("account", use: show)
        protected.post("account", "password", use: changePassword)
        protected.post("account", "email", use: setEmail)
        protected.post("account", "tmdb-token", use: saveToken)
        protected.post("account", "tmdb-token", "remove", use: removeToken)
        protected.get("account", "tmdb-refresh", use: refreshStatus)
        protected.post("account", "tmdb-refresh", use: startRefresh)
        protected.post("account", "devices", use: createDeviceToken)
        protected.post("account", "devices", ":deviceID", "revoke", use: revokeDevice)
        protected.post("account", "oidc", "link", use: startLink)
        protected.post("account", "oidc", "reauth", use: startReauth)
        protected.post("account", "notifications", use: saveNotifications)
        protected.post("account", "notifications", "webhook-key", use: saveWebhookKey)
        protected.post("account", "notifications", "webhook-key", "remove", use: removeWebhookKey)
        protected.post("account", "notifications", "test", use: testNotification)
    }

    // MARK: - Benachrichtigungen

    func saveNotifications(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(NotificationPrefsInput.self)
        let user = try req.currentUser
        let on = { (value: String?) in !(value ?? "").isEmpty }
        let channel = input.channel.flatMap(NotifyChannel.init(rawValue:)) ?? user.preferredChannel
        do {
            try await req.notificationPrefs.save(user: user, announced: on(input.announced), soon: on(input.soon), today: on(input.today),
                                                 channel: channel, available: try await req.notifications.availableChannels(for: user))
        } catch let error as APIError {
            return try await page(req, open: .notifications, status: error.status, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Benachrichtigungen gespeichert.")
    }

    func saveWebhookKey(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(WebhookKeyInput.self)
        do {
            try await req.notificationPrefs.setWebhookKey(user: try req.currentUser, key: input.key)
        } catch let error as APIError {
            return try await page(req, open: .notifications, status: error.status, error: error.message)
        }
        let removed = input.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return try await page(req, open: .notifications, notice: removed ? "Webhook-Schlüssel entfernt." : "Webhook-Schlüssel gespeichert.")
    }

    func removeWebhookKey(req: Request) async throws -> HTMLResponse {
        do {
            try await req.notificationPrefs.setWebhookKey(user: try req.currentUser, key: "")
        } catch let error as APIError {
            return try await page(req, open: .notifications, status: error.status, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Webhook-Schlüssel entfernt.")
    }

    func testNotification(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        do {
            try await req.notifications.send(NotificationTexts.test(username: user.username), to: user)
        } catch let error as NotifyError {
            return try await page(req, open: .notifications, status: error == .notConfigured ? .unprocessableEntity : .serviceUnavailable, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Testnachricht gesendet.")
    }

    /// „Über … bestätigen“: SSO accounts confirm through the provider before they get a manual token.
    func startReauth(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.oidc != nil else { throw Abort(.notFound) }
        req.session.data[OIDCController.intentKey] = OIDCIntent.reauth.rawValue
        req.session.data[OIDCController.returnToKey] = "/account?open=devices"
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
            return try await page(req, open: .sso, status: .unprocessableEntity, error: OIDCLoginService.alreadyLinked(oidc).message).encodeResponse(for: req)
        }
        // Like the e-mail address: a hijacked session must not bind the account to someone else's identity.
        if user.hasPassword {
            let entered = (try? req.content.decode(LinkInput.self).currentPassword) ?? ""
            guard try await req.password.async.verify(entered, created: user.passwordHash) else {
                return try await page(req, open: .sso, status: .unprocessableEntity, error: AccountValidation.wrongCurrentPasswordMessage)
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
            return try await page(req, open: .devices, status: .forbidden, error: "Bitte zuerst über \(ssoName) bestätigen – danach das Token erstellen.")
        }
        let name = try req.content.decode(DeviceInput.self).name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else {
            return try await page(req, open: .devices, status: .unprocessableEntity, error: "Der Name muss 1 bis 60 Zeichen haben.")
        }
        let issued = try await APITokenService(db: req.db).issue(userID: try req.userID, name: name, kind: .manual)
        return try await page(req, open: .devices, newToken: issued.token)
    }

    func revokeDevice(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("deviceID", as: UUID.self) else { throw Abort(.notFound) }
        try await APITokenService(db: req.db).revoke(id: id, userID: try req.userID)
        return try await page(req, open: .devices, notice: "Gerät abgemeldet.")
    }

    func show(req: Request) async throws -> HTMLResponse {
        // After accepting an invitation (see PasswordResetController).
        let welcome = (try? req.query.get(String.self, at: "welcome")) == "1"
        let name = req.application.loginSettings.current.oidc?.displayName ?? "SSO"
        switch try? req.query.get(String.self, at: "sso") {
        case "linked": return try await page(req, open: .sso, notice: "Mit \(name) verknüpft.")
        case "taken": return try await page(req, open: .sso, error: "Dieses \(name)-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.")
        case "host":
            let address = req.application.loginSettings.current.oidc?.canonicalOrigin ?? ""
            return try await page(req, open: .sso, notice: "Verknüpfen geht nur über \(address) – dort erneut anmelden und klicken.")
        default: break
        }
        // `?open=devices` after „Über … bestätigen“; unknown values open nothing.
        let open = welcome ? .tmdb : (try? req.query.get(String.self, at: "open")).flatMap(AccountBlock.init(rawValue:))
        return try await page(req, open: open, notice: welcome ? "Willkommen – trag hier deinen TMDB-Token ein." : nil)
    }

    func changePassword(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let input = try req.content.decode(ChangeInput.self)
        do {
            try await req.account.changePassword(user: try req.currentUser, current: input.currentPassword, new: input.newPassword)
        } catch let error as APIError {
            return try await page(req, open: .password, status: error.status, error: error.message)
        }
        return try await page(req, open: .password, notice: "Passwort geändert.")
    }

    func setEmail(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(EmailInput.self)
        do {
            try await req.account.setEmail(user: try req.currentUser, email: input.email, currentPassword: input.currentPassword)
        } catch let error as APIError {
            return try await page(req, open: .email, status: error.status, error: error.message)
        }
        let removed = input.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return try await page(req, open: .email, notice: removed ? "E-Mail-Adresse entfernt." : "E-Mail-Adresse gespeichert.")
    }

    /// Stores the user's TMDB token after TMDB accepted it.
    func saveToken(req: Request) async throws -> HTMLResponse {
        let token = try req.content.decode(TokenInput.self).token
        do {
            try await req.account.saveTMDBToken(user: try req.currentUser, token: token)
        } catch let error as APIError {
            return try await page(req, open: .tmdb, status: error.status, error: error.message)
        }
        return try await page(req, open: .tmdb, notice: "TMDB-Token gespeichert.")
    }

    func removeToken(req: Request) async throws -> HTMLResponse {
        try await req.account.removeTMDBToken(user: try req.currentUser)
        return try await page(req, open: .tmdb, notice: "TMDB-Token entfernt.")
    }

    // MARK: - Alle Daten von TMDB neu laden

    func refreshStatus(req: Request) async throws -> HTMLResponse {
        HTMLResponse(LibraryRefreshStatus(state: await req.application.libraryRefresh.state(userID: try req.userID)))
    }

    func startRefresh(req: Request) async throws -> HTMLResponse {
        let refresh = req.application.libraryRefresh
        let userID = try req.userID
        guard let token = req.tmdbToken else {
            let message = TMDBError.missingToken.description
            guard req.isHTMX else { return try await page(req, open: .tmdb, status: .unprocessableEntity, error: message) }
            return HTMLResponse(status: .unprocessableEntity, LibraryRefreshStatus(state: await refresh.state(userID: userID), error: message))
        }
        let state = try await refresh.start(userID: userID, token: token)
        return req.isHTMX ? HTMLResponse(LibraryRefreshStatus(state: state)) : try await page(req, open: .tmdb)
    }

    private func page(_ req: Request, open: AccountBlock? = nil, status: HTTPStatus = .ok, error: String? = nil,
                      notice: String? = nil, newToken: String? = nil) async throws -> HTMLResponse {
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
        let notifySettings = try await req.notificationSettings.settings()
        let available = try await req.notifications.availableChannels(for: user)
        let notifications = AccountNotifications(
            announced: user.notifyAnnounced == true, soon: user.notifySoon == true, today: user.notifyToday == true,
            available: available, active: available.contains(user.preferredChannel) ? user.preferredChannel : available.first,
            preferred: user.preferredChannel, webhookConfigured: notifySettings.webhookURL != nil,
            keyState: user.webhookKeyState(req.application.tokenCipher), dailyRunTime: notifySettings.dailyRunTime)
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice,
                                                        followed: followed, tokenUnreadable: unreadable, devices: devices,
                                                        newToken: newToken, email: user.emailState(req.application.tokenCipher),
                                                        mailConfigured: mailConfigured, sso: sso,
                                                        passwordChange: user.hasPassword && config.passwordLogin,
                                                        tokenNeedsReauth: try tokenNeedsReauth(req), notifications: notifications,
                                                        openBlock: open,
                                                        libraryRefresh: await req.application.libraryRefresh.state(userID: try req.userID)))
    }
}
