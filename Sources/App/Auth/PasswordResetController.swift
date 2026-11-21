import Fluent
import Vapor

/// `/reset-password`: sets a password from a one-time link (reset or invitation). GET only shows the form – mail
/// scanners open links in advance, so only the POST uses the token up.
struct PasswordResetController {
    /// Form fields of `POST /reset-password`.
    struct ResetInput: Content {
        var token: String
        var password: String
        var passwordRepeat: String
    }

    static let mismatchMessage = "Die Passwörter stimmen nicht überein."
    /// The token is in the URL: keep it out of Referer headers (only the origin is sent) and caches. Not `no-referrer`:
    /// with it browsers send `Origin: null` on the form POST, which the Origin check rejects.
    static let headers: HTTPHeaders = ["Referrer-Policy": "strict-origin", "Cache-Control": "no-store"]

    /// Form field of `POST /forgot-password`.
    struct ForgotInput: Content { var username: String }

    /// Registers `GET`/`POST /reset-password` and `GET`/`POST /forgot-password` behind the session authenticator.
    /// - Parameter routes: The public routes builder.
    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("reset-password", use: show)
        sessioned.post("reset-password", use: submit)
        sessioned.get("forgot-password", use: forgotPage)
        sessioned.post("forgot-password", use: forgot)
    }

    /// `GET /forgot-password`: renders the „Passwort vergessen“ (forgot password) page, which says whether mail is set up.
    /// - Parameter req: The request.
    /// - Returns: The page.
    /// - Throws: `Abort(.notFound)` while the password login is off; errors reading the mail settings.
    func forgotPage(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        return HTMLResponse(ForgotPasswordPage(mailEnabled: try await req.mailSettings.state().settings != nil))
    }

    /// Answers at once and identically for every username; the mail goes out in the background.
    ///
    /// `POST /forgot-password`: starts `ForgotPasswordService.handle` as a background task and renders the page in its
    /// sent state (or the page without mail when mail is not set up).
    /// - Parameter req: The request with the username.
    /// - Returns: The forgot-password page.
    /// - Throws: `Abort(.notFound)` while the password login is off; content decoding errors or errors reading the
    ///   mail settings.
    func forgot(req: Request) async throws -> HTMLResponse {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let username = try req.content.decode(ForgotInput.self).username
        guard try await req.mailSettings.state().settings != nil else { return HTMLResponse(ForgotPasswordPage(mailEnabled: false)) }
        let service = req.forgotPassword
        req.application.backgroundTasks.run { await service.handle(username: username) }
        return HTMLResponse(ForgotPasswordPage(mailEnabled: true, sent: true))
    }

    /// `GET /reset-password?token=…`: renders the form for setting a password without using the token up.
    ///
    /// A usable reset link counts as invalid while the password login is off; invitations are shown either way.
    /// - Parameter req: The request with the `token` query parameter.
    /// - Returns: The reset page with the form or the problem.
    /// - Throws: Database errors.
    func show(req: Request) async throws -> HTMLResponse {
        let token = (try? req.query.get(String.self, at: "token")) ?? ""
        switch try await PasswordTokenService(db: req.db).check(token) {
        case .success(let record) where record.tokenPurpose == .reset && !req.application.loginSettings.current.passwordLogin:
            return page(problem: .invalid)
        case .success(let record): return page(token: token, purpose: record.tokenPurpose, config: req.application.loginSettings.current)
        case .failure(let problem): return page(problem: problem)
        }
    }

    /// `POST /reset-password`: sets the password from the link, signs the user in on a new session and redirects to
    /// `/account?welcome=1` after an invitation or to `/` after a reset.
    ///
    /// An unusable link, differing passwords or a too short password re-render the page with the message.
    /// - Parameter req: The request with token, password and repetition.
    /// - Returns: The redirect, or the reset page with an error.
    /// - Throws: `Abort(.notFound)` while the password login is off; decoding and database errors.
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
        try await req.signInWithNewSession(user)
        let response = req.redirect(to: purpose == .invite ? "/account?welcome=1" : "/", redirectType: .normal)
        for (name, value) in Self.headers { response.headers.replaceOrAdd(name: name, value: value) }
        return response
    }

    /// Renders the reset page with the `headers` (`Referrer-Policy: strict-origin`, `Cache-Control: no-store`).
    /// - Parameters:
    ///   - token: The token to keep in the form, or `nil` when the link is unusable.
    ///   - purpose: Reset or invitation (changes the wording).
    ///   - problem: Why the link cannot be used, if so.
    ///   - status: The HTTP status.
    ///   - error: A form error, e.g. differing passwords.
    ///   - config: The login setup, for the provider button and whether passwords work.
    /// - Returns: The HTML response.
    private func page(token: String? = nil, purpose: PasswordTokenPurpose = .reset, problem: PasswordLinkProblem? = nil,
                      status: HTTPStatus = .ok, error: String? = nil, config: LoginSettings? = nil) -> HTMLResponse {
        HTMLResponse(status: status, headers: Self.headers,
                     ResetPasswordPage(token: token, purpose: purpose, problem: problem?.message, error: error,
                                       ssoName: config?.oidc?.displayName, passwordLogin: config?.passwordLogin ?? true))
    }
}
