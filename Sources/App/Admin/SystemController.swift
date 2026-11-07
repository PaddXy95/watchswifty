import Fluent
import Vapor

struct SystemController {
    func register(on protected: any RoutesBuilder) {
        let system = protected.grouped(RequireAdminMiddleware()).grouped("admin", "system")
        system.get(use: show)
        system.post("update-check", use: toggle)
        system.post("check-now", use: checkNow)
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

    private func page(_ req: Request, notice: String? = nil) async throws -> HTMLResponse {
        let settings = try await req.application.updates.settings()
        return HTMLResponse(SystemPage(nav: try req.nav(.system), current: req.application.appConfig.appVersion,
                                       state: UpdateState(settings), notice: notice))
    }
}
