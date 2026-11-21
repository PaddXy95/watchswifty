import Fluent
import Vapor

/// Web routes of the „Konto“ (account) page under `/account`, for the logged-in user's own settings.
///
/// Validation errors re-render the page with the message and the affected block opened.
struct AccountController {
    /// Form fields for changing the password.
    struct ChangeInput: Content { var currentPassword: String; var newPassword: String }
    /// Form field with a TMDB token.
    struct TokenInput: Content { var token: String }
    /// Form field with the name of a new manual API token.
    struct DeviceInput: Content { var name: String }
    /// Form fields for setting the e-mail address (confirmed with the current password).
    struct EmailInput: Content { var email: String; var currentPassword: String }
    /// Form field with the current password for linking with the OIDC provider.
    struct LinkInput: Content { var currentPassword: String? }
    /// Notification checkboxes (non-empty when checked) and the preferred channel.
    struct NotificationPrefsInput: Content { var announced: String?; var soon: String?; var today: String?; var available: String?; var channel: String? }
    /// Form field with the user's KNot webhook key (empty removes it).
    struct WebhookKeyInput: Content { var key: String }
    /// Form fields for the streaming region and the selected TMDB provider IDs.
    struct StreamingInput: Content { var region: String; var providers: [Int]? }

    /// Registers the account routes in the protected (logged-in) group.
    /// - Parameter protected: The route group requiring a logged-in user.
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
        protected.post("account", "streaming", use: saveStreaming)
        protected.get("account", "streaming", "providers", use: streamingProviders)
        protected.post("account", "notifications", "webhook-key", use: saveWebhookKey)
        protected.post("account", "notifications", "webhook-key", "remove", use: removeWebhookKey)
        protected.post("account", "notifications", "test", use: testNotification)
    }

    // MARK: - Streamingdienste

    /// `POST /account/streaming`: stores the streaming region and services.
    ///
    /// When the region changed and the user has a TMDB token, missing availability data is fetched in the background.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Decoding and database errors.
    func saveStreaming(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(StreamingInput.self)
        let user = try req.currentUser
        let changedRegion: Bool
        do {
            changedRegion = try await req.streamingSettings.save(user: user, region: input.region, providerIDs: input.providers ?? [])
        } catch let error as APIError {
            return try await page(req, open: .streaming, status: error.status, error: error.message)
        }
        if changedRegion, let token = req.tmdbToken {
            let app = req.application, userID = try user.requireID(), region = user.region
            app.backgroundTasks.run {
                await StreamingSettingsService(db: app.db).fetchMissing(userID: userID, region: region, tmdb: app.tmdbProvider.make(token),
                                                                        logger: app.logger)
            }
        }
        return try await page(req, open: .streaming, notice: "Streamingdienste gespeichert.")
    }

    /// `GET /account/streaming/providers?region=XX`: the checkboxes for another country (htmx, when the country
    /// changes).
    /// - Parameter req: The incoming request.
    /// - Returns: The provider checkbox fragment for the region.
    /// - Throws: `Abort(.badRequest)` unless `region` is two letters; TMDB and database errors.
    func streamingProviders(req: Request) async throws -> HTMLResponse {
        let region = ((try? req.query.get(String.self, at: "region")) ?? "").uppercased()
        guard region.count == 2, region.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { throw Abort(.badRequest) }
        let user = try req.currentUser
        let providers = try await req.application.providerCatalog.providers(region: region, tmdb: req.tmdb)
        let selected = try await req.streamingSettings.settings(user: user).providerIDs
        return HTMLResponse(StreamingProviderChoices(providers: providers, selected: selected))
    }

    /// Builds the streaming block: region, selectable regions and the region's providers from TMDB.
    /// - Parameters:
    ///   - req: The incoming request.
    ///   - user: The logged-in user.
    /// - Returns: The block state; without TMDB token only the stored selection, with a load error when TMDB fails.
    /// - Throws: Database errors.
    private func streamingState(_ req: Request, user: User) async throws -> AccountStreaming {
        let settings = try await req.streamingSettings.settings(user: user)
        var state = AccountStreaming(region: settings.region, regions: [], providers: [], selected: settings.providerIDs,
                                     hasToken: req.tmdbToken != nil)
        guard state.hasToken else { return state }
        do {
            let catalog = req.application.providerCatalog
            state.regions = try await catalog.regions(tmdb: req.tmdb)
            if !state.regions.contains(where: { $0.code == settings.region }) {
                state.regions.insert(TMDBRegion(code: settings.region, name: settings.region), at: 0)
            }
            state.providers = try await catalog.providers(region: settings.region, tmdb: req.tmdb)
        } catch let error as TMDBError {
            state.loadError = "Die Streamingdienste konnten nicht von TMDB geladen werden: \(error)"
        }
        return state
    }

    // MARK: - Benachrichtigungen

    /// `POST /account/notifications`: stores the notification preferences and channel.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Decoding and database errors.
    func saveNotifications(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(NotificationPrefsInput.self)
        let user = try req.currentUser
        let on = { (value: String?) in !(value ?? "").isEmpty }
        let channel = input.channel.flatMap(NotifyChannel.init(rawValue:)) ?? user.preferredChannel
        do {
            try await req.notificationPrefs.save(user: user, announced: on(input.announced), soon: on(input.soon), today: on(input.today),
                                                 titleAvailable: on(input.available),
                                                 channel: channel, available: try await req.notifications.availableChannels(for: user))
        } catch let error as APIError {
            return try await page(req, open: .notifications, status: error.status, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Benachrichtigungen gespeichert.")
    }

    /// `POST /account/notifications/webhook-key`: stores (or with an empty value removes) the KNot webhook key.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Decoding and database errors.
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

    /// `POST /account/notifications/webhook-key/remove`: removes the KNot webhook key.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Database errors.
    func removeWebhookKey(req: Request) async throws -> HTMLResponse {
        do {
            try await req.notificationPrefs.setWebhookKey(user: try req.currentUser, key: "")
        } catch let error as APIError {
            return try await page(req, open: .notifications, status: error.status, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Webhook-Schlüssel entfernt.")
    }

    /// `POST /account/notifications/test`: sends a test notification over the user's channel.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with a 422 (not configured) or 503 error.
    /// - Throws: Database errors.
    func testNotification(req: Request) async throws -> HTMLResponse {
        let user = try req.currentUser
        do {
            try await req.notifications.send(NotificationTexts.test(username: user.username), to: user)
        } catch let error as NotifyError {
            return try await page(req, open: .notifications, status: error == .notConfigured ? .unprocessableEntity : .serviceUnavailable, error: error.message)
        }
        return try await page(req, open: .notifications, notice: "Testnachricht gesendet.")
    }

    /// `POST /account/oidc/reauth` („Über … bestätigen“): SSO accounts confirm through the provider before they get a
    /// manual token.
    /// - Parameter req: The incoming request.
    /// - Returns: A redirect to `/auth/oidc/start`, returning to `/account?open=devices`.
    /// - Throws: `Abort(.notFound)` when SSO is not set up.
    func startReauth(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.oidc != nil else { throw Abort(.notFound) }
        req.session.data[OIDCController.intentKey] = OIDCIntent.reauth.rawValue
        req.session.data[OIDCController.returnToKey] = "/account?open=devices"
        return req.redirect(to: "/auth/oidc/start", redirectType: .normal)
    }

    /// SSO accounts get no new API token without a fresh confirmation by the provider (spec „App verbinden“).
    /// - Parameter req: The incoming request.
    /// - Returns: Whether the user must confirm through the provider before creating a token.
    /// - Throws: When no user is logged in.
    private func tokenNeedsReauth(_ req: Request) throws -> Bool {
        let login = req.application.loginSettings.current
        return try req.currentUser.isSSOAccount(login.oidc, passwordLogin: login.passwordLogin)
            && !OIDCController.isFresh(verifiedAt: req.session.data[OIDCController.verifiedAtKey], now: .now)
    }

    /// `POST /account/oidc/link` („Mit … verknüpfen“): remembers the intent in the (signed-in) session and starts the
    /// provider flow on the canonical address. Accounts with a password must enter it.
    /// - Parameter req: The incoming request.
    /// - Returns: A redirect to `/auth/oidc/start`; to `<canonical address>/account?sso=host` when the request came from
    ///   another host; or the page with a 422 error when already linked or the password is wrong.
    /// - Throws: `Abort(.notFound)` when SSO is not set up.
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

    /// `POST /account/devices`: issues a manual API token for scripts or trying out the API docs; shown only in this
    /// response.
    /// - Parameter req: The incoming request.
    /// - Returns: The page showing the new token, or with a 403 (confirmation needed) or 422 (invalid name) error.
    /// - Throws: Decoding and database errors.
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

    /// `POST /account/devices/:deviceID/revoke`: revokes one of the user's API tokens.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice and the devices block open.
    /// - Throws: `Abort(.notFound)` for an invalid ID, `APIError.notFound` for an unknown or another user's token;
    ///   database errors.
    func revokeDevice(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("deviceID", as: UUID.self) else { throw Abort(.notFound) }
        try await APITokenService(db: req.db).revoke(id: id, userID: try req.userID)
        return try await page(req, open: .devices, notice: "Gerät abgemeldet.")
    }

    /// `GET /account`: renders the account page, with notices for `?sso=` results and `?welcome=1`, opening the block
    /// named by `?open=`.
    /// - Parameter req: The incoming request.
    /// - Returns: The account page.
    /// - Throws: Database errors.
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

    /// `POST /account/password`: changes the user's password.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: `Abort(.notFound)` when password login is off; decoding and database errors.
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

    /// `POST /account/email`: sets or removes the user's e-mail address.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Decoding and database errors.
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

    /// `POST /account/tmdb-token`: stores the user's TMDB token after TMDB accepted it.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the validation error.
    /// - Throws: Decoding and database errors.
    func saveToken(req: Request) async throws -> HTMLResponse {
        let token = try req.content.decode(TokenInput.self).token
        do {
            try await req.account.saveTMDBToken(user: try req.currentUser, token: token)
        } catch let error as APIError {
            return try await page(req, open: .tmdb, status: error.status, error: error.message)
        }
        return try await page(req, open: .tmdb, notice: "TMDB-Token gespeichert.")
    }

    /// `POST /account/tmdb-token/remove`: removes the user's TMDB token.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice.
    /// - Throws: Database errors.
    func removeToken(req: Request) async throws -> HTMLResponse {
        try await req.account.removeTMDBToken(user: try req.currentUser)
        return try await page(req, open: .tmdb, notice: "TMDB-Token entfernt.")
    }

    // MARK: - Alle Daten von TMDB neu laden

    /// `GET /account/tmdb-refresh`: renders the status fragment of the library reload (polled by htmx).
    /// - Parameter req: The incoming request.
    /// - Returns: The status fragment.
    /// - Throws: When no user is logged in.
    func refreshStatus(req: Request) async throws -> HTMLResponse {
        HTMLResponse(LibraryRefreshStatus(state: await req.application.libraryRefresh.state(userID: try req.userID)))
    }

    /// `POST /account/tmdb-refresh`: starts reloading all of the user's data from TMDB.
    /// - Parameter req: The incoming request.
    /// - Returns: The status fragment for htmx, otherwise the page; 422 without TMDB token.
    /// - Throws: Errors from starting the reload or rendering the page.
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

    /// Renders the account page with token, devices, e-mail, SSO, notification, streaming and reload state.
    /// - Parameters:
    ///   - req: The incoming request.
    ///   - open: The block to open.
    ///   - status: HTTP status of the response.
    ///   - error: German error message to show.
    ///   - notice: German success notice to show.
    ///   - newToken: A freshly issued API token, shown only in this response.
    /// - Returns: The rendered page.
    /// - Throws: Database errors.
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
            keyState: user.webhookKeyState(req.application.tokenCipher), dailyRunTime: notifySettings.dailyRunTime,
            titleAvailable: user.notifyAvailable == true)
        return HTMLResponse(status: status, AccountPage(nav: try req.nav(.account), tokenSuffix: suffix, error: error, notice: notice,
                                                        followed: followed, tokenUnreadable: unreadable, devices: devices,
                                                        newToken: newToken, email: user.emailState(req.application.tokenCipher),
                                                        mailConfigured: mailConfigured, sso: sso,
                                                        passwordChange: user.hasPassword && config.passwordLogin,
                                                        tokenNeedsReauth: try tokenNeedsReauth(req), notifications: notifications,
                                                        streaming: try await streamingState(req, user: user), openBlock: open,
                                                        libraryRefresh: await req.application.libraryRefresh.state(userID: try req.userID)))
    }
}
