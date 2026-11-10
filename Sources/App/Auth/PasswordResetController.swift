import Fluent
import Vapor

/// `/reset-password`: sets a password from a one-time link (reset or invitation). GET only shows the form – mail
/// scanners open links in advance, so only the POST uses the token up.
struct PasswordResetController {
    struct ResetInput: Content {
        var token: String
        var password: String
        var passwordRepeat: String
    }

    static let mismatchMessage = "Die Passwörter stimmen nicht überein."
    /// The token is in the URL: keep it out of Referer headers (only the origin is sent) and caches. Not `no-referrer`:
    /// with it browsers send `Origin: null` on the form POST, which the Origin check rejects.
    static let headers: HTTPHeaders = ["Referrer-Policy": "strict-origin", "Cache-Control": "no-store"]

    struct ForgotInput: Content { var username: String }

    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("reset-password", use: show)
        sessioned.post("reset-password", use: submit)
        sessioned.get("forgot-password", use: forgotPage)
        sessioned.post("forgot-password", use: forgot)
    }

    func forgotPage(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        return HTMLResponse(ForgotPasswordPage(mailEnabled: try await req.mailSettings.state().settings != nil))
    }

    /// Answers at once and identically for every username; the mail goes out in the background.
    func forgot(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let username = try req.content.decode(ForgotInput.self).username
        guard try await req.mailSettings.state().settings != nil else { return HTMLResponse(ForgotPasswordPage(mailEnabled: false)) }
        let service = req.forgotPassword
        req.application.backgroundTasks.run { await service.handle(username: username) }
        return HTMLResponse(ForgotPasswordPage(mailEnabled: true, sent: true))
    }

    func show(req: Request) async throws -> HTMLResponse {
        let token = (try? req.query.get(String.self, at: "token")) ?? ""
        switch try await PasswordTokenService(db: req.db).check(token) {
        case .success(let record) where record.tokenPurpose == .reset && !req.application.loginSettings.current.passwordLogin:
            return page(problem: .invalid)
        case .success(let record): return page(token: token, purpose: record.tokenPurpose, config: req.application.loginSettings.current)
        case .failure(let problem): return page(problem: problem)
        }
    }

    func submit(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let input = try req.content.decode(ResetInput.self)
        let service = PasswordTokenService(db: req.db)
        let record: PasswordToken
        switch try await service.check(input.token) {
        case .success(let found): record = found
        case .failure(let problem): return try await page(problem: problem).encodeResponse(for: req)
        }
        guard input.password == input.passwordRepeat else {
            return try await page(token: input.token, purpose: record.tokenPurpose, status: .unprocessableEntity,
                                  error: Self.mismatchMessage, config: req.application.loginSettings.current).encodeResponse(for: req)
        }
        let user: User
        let purpose: PasswordTokenPurpose
        do {
            (user, purpose) = try await service.setPassword(token: input.token, password: input.password, hasher: req.password.async)
        } catch let problem as PasswordLinkProblem {
            return try await page(problem: problem).encodeResponse(for: req)
        } catch let error as APIError {
            return try await page(token: input.token, purpose: record.tokenPurpose, status: error.status, error: error.message,
                                  config: req.application.loginSettings.current).encodeResponse(for: req)
        }
        req.auth.login(user)
        req.session.authenticate(user)
        let response = req.redirect(to: purpose == .invite ? "/account?welcome=1" : "/", redirectType: .normal)
        for (name, value) in Self.headers { response.headers.replaceOrAdd(name: name, value: value) }
        return response
    }

    private func page(token: String? = nil, purpose: PasswordTokenPurpose = .reset, problem: PasswordLinkProblem? = nil,
                      status: HTTPStatus = .ok, error: String? = nil, config: LoginSettings? = nil) -> HTMLResponse {
        HTMLResponse(status: status, headers: Self.headers,
                     ResetPasswordPage(token: token, purpose: purpose, problem: problem?.message, error: error,
                                       ssoName: config?.oidc?.displayName, passwordLogin: config?.passwordLogin ?? true))
    }
}
