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
    /// The token is in the URL: keep it out of Referer headers and caches.
    static let headers: HTTPHeaders = ["Referrer-Policy": "no-referrer", "Cache-Control": "no-store"]

    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("reset-password", use: show)
        sessioned.post("reset-password", use: submit)
    }

    func show(req: Request) async throws -> HTMLResponse {
        let token = (try? req.query.get(String.self, at: "token")) ?? ""
        switch try await PasswordTokenService(db: req.db).check(token) {
        case .success(let record): return page(token: token, purpose: record.tokenPurpose)
        case .failure(let problem): return page(problem: problem)
        }
    }

    func submit(req: Request) async throws -> Response {
        let input = try req.content.decode(ResetInput.self)
        let service = PasswordTokenService(db: req.db)
        let record: PasswordToken
        switch try await service.check(input.token) {
        case .success(let found): record = found
        case .failure(let problem): return try await page(problem: problem).encodeResponse(for: req)
        }
        guard input.password == input.passwordRepeat else {
            return try await page(token: input.token, purpose: record.tokenPurpose, status: .unprocessableEntity,
                                  error: Self.mismatchMessage).encodeResponse(for: req)
        }
        let user: User
        let purpose: PasswordTokenPurpose
        do {
            (user, purpose) = try await service.setPassword(token: input.token, password: input.password, hasher: req.password.async)
        } catch let problem as PasswordLinkProblem {
            return try await page(problem: problem).encodeResponse(for: req)
        } catch let error as APIError {
            return try await page(token: input.token, purpose: record.tokenPurpose, status: error.status, error: error.message)
                .encodeResponse(for: req)
        }
        req.auth.login(user)
        req.session.authenticate(user)
        let response = req.redirect(to: purpose == .invite ? "/account?welcome=1" : "/", redirectType: .normal)
        for (name, value) in Self.headers { response.headers.replaceOrAdd(name: name, value: value) }
        return response
    }

    private func page(token: String? = nil, purpose: PasswordTokenPurpose = .reset, problem: PasswordLinkProblem? = nil,
                      status: HTTPStatus = .ok, error: String? = nil) -> HTMLResponse {
        HTMLResponse(status: status, headers: Self.headers,
                     ResetPasswordPage(token: token, purpose: purpose, problem: problem?.message, error: error))
    }
}
