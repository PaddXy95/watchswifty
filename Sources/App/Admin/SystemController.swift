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
    }

    func show(req: Request) async throws -> HTMLResponse {
        try await page(req)
    }

    /// Turning automatic checks on asks GitHub at once, so the admin sees the result.
    func toggle(req: Request) async throws -> HTMLResponse {
        // An unchecked checkbox sends nothing, so the body may be empty.
        let enabled = ((try? req.content.get(String.self, at: "enabled")) ?? "").isEmpty == false
        let updates = req.application.updates
        let wasEnabled = try await updates.settings().updateCheck
        try await updates.setEnabled(enabled)
        if enabled && !wasEnabled { try await updates.checkNow() }
        return try await page(req, notice: enabled ? "Automatische Prüfung eingeschaltet." : "Automatische Prüfung ausgeschaltet.")
    }

    func checkNow(req: Request) async throws -> HTMLResponse {
        try await req.application.updates.checkNow()
        return try await page(req)
    }

    func saveMail(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(MailSettingsInput.self)
        do {
            try await req.mailSettings.save(input)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, mailForm: MailFormValues(input))
        }
        return try await page(req, notice: "E-Mail-Einstellungen gespeichert.")
    }

    func deleteMail(req: Request) async throws -> HTMLResponse {
        try await req.mailSettings.delete()
        return try await page(req, notice: "E-Mail-Einstellungen gelöscht.")
    }

    func testMail(req: Request) async throws -> HTMLResponse {
        let to = try req.content.decode(TestMailInput.self).to
        do {
            try await req.mail.sendTest(to: to)
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message, testRecipient: to)
        } catch let error as MailError {
            let apiError = APIError.from(error)
            return try await page(req, status: apiError.status, error: apiError.message, testRecipient: to)
        }
        return try await page(req, notice: "Testmail gesendet.", testRecipient: to)
    }

    private func page(_ req: Request, status: HTTPStatus = .ok, notice: String? = nil, error: String? = nil,
                      mailForm: MailFormValues? = nil, testRecipient: String? = nil) async throws -> HTMLResponse {
        let settings = try await req.application.updates.settings()
        let mail = try await req.mailSettings.state()
        let form = mailForm ?? mail.settings.map(MailFormValues.init) ?? MailFormValues(baseURL: Self.requestOrigin(req))
        return HTMLResponse(status: status, SystemPage(nav: try req.nav(.system), current: req.application.appConfig.appVersion,
                                                       state: UpdateState(settings), notice: notice, error: error, mail: mail,
                                                       mailForm: form, testRecipient: testRecipient))
    }

    /// Suggestion for „Adresse von WatchSwifty“ (only pre-fills the form; links use the stored value only).
    static func requestOrigin(_ req: Request) -> String {
        guard let host = req.headers.first(name: .host), !host.isEmpty else { return "" }
        let scheme = req.headers.first(name: "X-Forwarded-Proto")?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "http"
        return "\(scheme == "https" ? "https" : "http")://\(host)"
    }
}
