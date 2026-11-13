import Fluent
import Vapor

struct SystemController {
    struct TestMailInput: Content { var to: String }

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

    func show(req: Request) async throws -> HTMLResponse {
        // `?open=updates` (update hint in the footer); unknown values open nothing.
        try await page(req, open: (try? req.query.get(String.self, at: "open")).flatMap(SystemBlock.init(rawValue:)))
    }

    /// Turning automatic checks on asks GitHub at once, so the admin sees the result.
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

    func checkNow(req: Request) async throws -> HTMLResponse {
        try await req.application.updates.checkNow()
        return try await page(req, open: .updates)
    }

    func saveMail(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(MailSettingsInput.self)
        do {
            try await req.mailSettings.save(input)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, mailForm: MailFormValues(input), open: .mail)
        }
        return try await page(req, notice: "E-Mail-Einstellungen gespeichert.", open: .mail)
    }

    func deleteMail(req: Request) async throws -> HTMLResponse {
        try await req.mailSettings.delete()
        return try await page(req, notice: "E-Mail-Einstellungen gelöscht.", open: .mail)
    }

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

    struct NotificationsInput: Content {
        var dailyRunTime: String
        var webhookURL: String?
    }

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

    func deleteWebhook(req: Request) async throws -> HTMLResponse {
        try await req.notificationSettings.removeWebhook()
        return try await page(req, notice: "Webhook entfernt.", open: .notifications)
    }

    // MARK: - Anmeldung (SSO)

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

    func testOIDC(req: Request) async throws -> HTMLResponse {
        guard let config = req.application.loginSettings.current.oidc else {
            return try await page(req, status: .unprocessableEntity, error: OIDCSettingsService.needsOIDCMessage, open: .oidc)
        }
        switch await Self.check(req, config) {
        case .success(let text): return try await page(req, notice: text, open: .oidc)
        case .failure(let failure): return try await page(req, status: .serviceUnavailable, error: failure.message, open: .oidc)
        }
    }

    func deleteOIDC(req: Request) async throws -> HTMLResponse {
        do {
            try await req.oidcSettings.delete()
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, open: .oidc)
        }
        return try await page(req, notice: "Anmelde-Einstellungen gelöscht.", open: .oidc)
    }

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

    struct CheckFailure: Error { let message: String }

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
    static func requestOrigin(_ req: Request) -> String {
        guard let host = req.headers.first(name: .host), !host.isEmpty else { return "" }
        let scheme = req.headers.first(name: "X-Forwarded-Proto")?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "http"
        return "\(scheme == "https" ? "https" : "http")://\(host)"
    }
}
