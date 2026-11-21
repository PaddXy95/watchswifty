import Fluent
import Vapor

/// Web routes of the admin page „System“ under `/admin/system`: update check, mail, notifications and SSO login.
///
/// All routes are admin-only (`RequireAdminMiddleware`); validation errors re-render the page with the message (and the
/// entered values where the block has a form), with the affected block opened.
struct SystemController {
    /// Form field with the recipient of a test mail.
    struct TestMailInput: Content { var to: String }

    /// Registers the system routes behind `RequireAdminMiddleware`.
    /// - Parameter protected: The route group requiring a logged-in user.
    func register(on protected: any RoutesBuilder) {
        let system = protected.grouped(RequireAdminMiddleware()).grouped("admin", "system")
        system.get(use: show)
        system.post("update-check", use: toggle)
        system.post("check-now", use: checkNow)
        system.post("mail", use: saveMail)
        system.post("mail", "delete", use: deleteMail)
        system.post("mail", "test", use: testMail)
        system.post("notifications", use: saveNotifications)
        system.post("notifications", "webhook", "delete", use: deleteWebhook)
        system.post("oidc", use: saveOIDC)
        system.post("oidc", "test", use: testOIDC)
        system.post("oidc", "delete", use: deleteOIDC)
        system.post("password-login", use: setPasswordLogin)
    }

    /// `GET /admin/system`: renders the system page, opening the block named by `?open=`.
    /// - Parameter req: The incoming request.
    /// - Returns: The system page.
    /// - Throws: Database errors.
    func show(req: Request) async throws -> HTMLResponse {
        // `?open=updates` (update hint in the footer); unknown values open nothing.
        try await page(req, open: (try? req.query.get(String.self, at: "open")).flatMap(SystemBlock.init(rawValue:)))
    }

    /// `POST /admin/system/update-check`: turns the automatic update check on or off.
    ///
    /// Turning automatic checks on asks GitHub at once, so the admin sees the result.
    /// - Parameter req: The incoming request (`enabled` is non-empty when checked).
    /// - Returns: The page with a notice and the updates block open.
    /// - Throws: Database errors.
    func toggle(req: Request) async throws -> HTMLResponse {
        // An unchecked checkbox sends nothing, so the body may be empty.
        let enabled = ((try? req.content.get(String.self, at: "enabled")) ?? "").isEmpty == false
        let updates = req.application.updates
        let wasEnabled = try await updates.settings().updateCheck
        try await updates.setEnabled(enabled)
        if enabled && !wasEnabled { try await updates.checkNow() }
        return try await page(req, notice: enabled ? "Automatische Prüfung eingeschaltet." : "Automatische Prüfung ausgeschaltet.",
                              open: .updates)
    }

    /// `POST /admin/system/check-now`: asks GitHub for the latest release right away.
    /// - Parameter req: The incoming request.
    /// - Returns: The system page with the updates block open.
    /// - Throws: Database errors.
    func checkNow(req: Request) async throws -> HTMLResponse {
        try await req.application.updates.checkNow()
        return try await page(req, open: .updates)
    }

    /// `POST /admin/system/mail`: validates and stores the SMTP settings (sealed with `TokenCipher`).
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error and the entered values.
    /// - Throws: Decoding and database errors.
    func saveMail(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(MailSettingsInput.self)
        do {
            try await req.mailSettings.save(input)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, mailForm: MailFormValues(input), open: .mail)
        }
        return try await page(req, notice: "E-Mail-Einstellungen gespeichert.", open: .mail)
    }

    /// `POST /admin/system/mail/delete`: removes the mail settings.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice.
    /// - Throws: Database errors.
    func deleteMail(req: Request) async throws -> HTMLResponse {
        try await req.mailSettings.delete()
        return try await page(req, notice: "E-Mail-Einstellungen gelöscht.", open: .mail)
    }

    /// `POST /admin/system/mail/test`: sends a test mail with the stored settings.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the validation or SMTP error.
    /// - Throws: Decoding and database errors.
    func testMail(req: Request) async throws -> HTMLResponse {
        let to = try req.content.decode(TestMailInput.self).to
        do {
            try await req.mail.sendTest(to: to)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, testRecipient: to, open: .mail)
        } catch let error as MailError {
            let apiError = APIError.from(error)
            return try await page(req, status: apiError.status, error: apiError.message, testRecipient: to, open: .mail)
        }
        return try await page(req, notice: "Testmail gesendet.", testRecipient: to, open: .mail)
    }

    // MARK: - Benachrichtigungen

    /// Form fields of the notifications block: daily run time (`HH:MM`) and optional KNot webhook URL.
    struct NotificationsInput: Content {
        var dailyRunTime: String
        var webhookURL: String?
    }

    /// `POST /admin/system/notifications`: stores the daily run time and the webhook address.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error and the entered values.
    /// - Throws: Decoding and database errors.
    func saveNotifications(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(NotificationsInput.self)
        do {
            try await req.notificationSettings.save(dailyRunTime: input.dailyRunTime, webhookURL: input.webhookURL)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message,
                                  notificationsForm: (input.dailyRunTime, input.webhookURL ?? ""), open: .notifications)
        }
        return try await page(req, notice: "Benachrichtigungen gespeichert.", open: .notifications)
    }

    /// `POST /admin/system/notifications/webhook/delete`: removes the KNot webhook.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice.
    /// - Throws: Database errors.
    func deleteWebhook(req: Request) async throws -> HTMLResponse {
        try await req.notificationSettings.removeWebhook()
        return try await page(req, notice: "Webhook entfernt.", open: .notifications)
    }

    // MARK: - Anmeldung (SSO)

    /// `POST /admin/system/oidc`: stores the OIDC setup and, if complete, tests the connection.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice including the test result, or with the validation or test error.
    /// - Throws: Decoding and database errors.
    func saveOIDC(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(OIDCSettingsInput.self)
        let saved: OIDCSettings
        do {
            saved = try await req.oidcSettings.save(input)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, oidcForm: OIDCFormValues(input), open: .oidc)
        }
        let notice = "Anmelde-Einstellungen gespeichert."
        guard let config = saved.config else { return try await page(req, notice: notice, open: .oidc) }
        switch await Self.check(req, config) {
        case .success(let text): return try await page(req, notice: notice + " " + text, open: .oidc)
        case .failure(let failure):
            return try await page(req, error: "Gespeichert, aber die Prüfung schlug fehl: \(failure.message)", open: .oidc)
        }
    }

    /// `POST /admin/system/oidc/test`: tests the stored OIDC setup.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with the result; 422 without setup, 503 when the test fails.
    /// - Throws: Database errors.
    func testOIDC(req: Request) async throws -> HTMLResponse {
        guard let config = req.application.loginSettings.current.oidc else {
            return try await page(req, status: .unprocessableEntity, error: OIDCSettingsService.needsOIDCMessage, open: .oidc)
        }
        switch await Self.check(req, config) {
        case .success(let text): return try await page(req, notice: text, open: .oidc)
        case .failure(let failure): return try await page(req, status: .serviceUnavailable, error: failure.message, open: .oidc)
        }
    }

    /// `POST /admin/system/oidc/delete`: removes the OIDC setup.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Database errors.
    func deleteOIDC(req: Request) async throws -> HTMLResponse {
        do {
            try await req.oidcSettings.delete()
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, open: .oidc)
        }
        return try await page(req, notice: "Anmelde-Einstellungen gelöscht.", open: .oidc)
    }

    /// `POST /admin/system/password-login`: turns password login on or off.
    /// - Parameter req: The incoming request.
    /// - Returns: The page with a notice, or with the error.
    /// - Throws: Database errors.
    func setPasswordLogin(req: Request) async throws -> HTMLResponse {
        let enabled = (try? req.content.get(String.self, at: "enabled")) == "true"
        do {
            try await req.oidcSettings.setPasswordLogin(enabled, actingUser: try req.currentUser)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, open: .oidc)
        }
        return try await page(req, notice: enabled ? "Passwort-Login eingeschaltet." : "Passwort-Login abgeschaltet.", open: .oidc)
    }

    /// „Verbindung testen“: discovery and keys afresh; the text for the page either way.
    /// - Parameters:
    ///   - req: The incoming request.
    ///   - config: The OIDC setup to test.
    /// - Returns: The German success text (issuer and key count), or a `CheckFailure` with the reason.
    static func check(_ req: Request, _ config: OIDCConfig) async -> Result<String, CheckFailure> {
        do {
            let result = try await req.application.oidcProviders.provider(for: config).check()
            return .success("Verbindung in Ordnung: Issuer \(result.issuer), \(result.keyCount) Schlüssel.")
        } catch let error as OIDCError {
            req.logger.warning("OIDC-Prüfung fehlgeschlagen: \(error.logDescription)")
            return .failure(CheckFailure(message: error.adminDescription(name: config.displayName)))
        } catch {
            return .failure(CheckFailure(message: "\(config.displayName) ist nicht erreichbar."))
        }
    }

    /// German message of a failed OIDC connection test.
    struct CheckFailure: Error { let message: String }

    /// Renders the system page with the update, mail, SSO and notification state.
    /// - Parameters:
    ///   - req: The incoming request.
    ///   - status: HTTP status of the response.
    ///   - notice: German success notice to show.
    ///   - error: German error message to show.
    ///   - mailForm: Entered mail values to show again after an error.
    ///   - testRecipient: Test mail recipient; defaults to the admin's own address.
    ///   - oidcForm: Entered OIDC values to show again after an error.
    ///   - notificationsForm: Entered notification values to show again after an error.
    ///   - open: The block to open.
    /// - Returns: The rendered page.
    /// - Throws: Database errors.
    private func page(_ req: Request, status: HTTPStatus = .ok, notice: String? = nil, error: String? = nil,
                      mailForm: MailFormValues? = nil, testRecipient: String? = nil,
                      oidcForm: OIDCFormValues? = nil, notificationsForm: (time: String, url: String)? = nil,
                      open: SystemBlock? = nil) async throws -> HTMLResponse {
        let settings = try await req.application.updates.settings()
        let mail = try await req.mailSettings.state()
        let form = mailForm ?? mail.settings.map(MailFormValues.init) ?? MailFormValues(baseURL: Self.requestOrigin(req))
        let ownAddress = try req.currentUser.emailState(req.application.tokenCipher).address
        let oidc = try await req.oidcSettings.state()
        let oidcValues = oidcForm ?? oidc.settings.map(OIDCFormValues.init)
            ?? OIDCFormValues(baseURL: mail.settings?.baseURL ?? Self.requestOrigin(req))
        let login = req.application.loginSettings.current
        let notifySettings = try await req.notificationSettings.settings()
        let notifications = NotificationsSection(settings: notifySettings, timeZone: TimeZone.current.identifier,
                                                 nextRun: DailySchedule.nextRun(after: .now, time: notifySettings.dailyRunTime, timeZone: .current),
                                                 entered: notificationsForm)
        return HTMLResponse(status: status, SystemPage(nav: try req.nav(.system), current: req.application.appConfig.appVersion,
                                                       state: UpdateState(settings), notice: notice, error: error, mail: mail,
                                                       mailForm: form, testRecipient: testRecipient ?? ownAddress,
                                                       oidc: OIDCSection(state: oidc, values: oidcValues, passwordLogin: login.passwordLogin,
                                                                         passwordLoginForced: login.passwordLoginForced),
                                                       notifications: notifications, openBlock: open))
    }

    /// Suggestion for „Adresse von WatchSwifty“ (only pre-fills the form; links use the stored value only).
    /// - Parameter req: The incoming request (`Host` and `X-Forwarded-Proto` headers).
    /// - Returns: `http(s)://host`, or an empty string without `Host` header.
    static func requestOrigin(_ req: Request) -> String {
        guard let host = req.headers.first(name: .host), !host.isEmpty else { return "" }
        let scheme = req.headers.first(name: "X-Forwarded-Proto")?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "http"
        return "\(scheme == "https" ? "https" : "http")://\(host)"
    }
}
