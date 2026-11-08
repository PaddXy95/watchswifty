import Vapor

/// Per-request state of an App API call (set by `APIContextMiddleware`, read by the handlers).
struct APIRequestState: Sendable {
    let request: Request
    let user: User?
    /// Why a presented token was not accepted (unknown or expired).
    let tokenProblem: APIError?
}

enum APIContext {
    @TaskLocal static var current: APIRequestState?

    static func request() throws -> Request {
        guard let current else { throw APIError(status: .internalServerError, code: "internal", message: "Interner Fehler.") }
        return current.request
    }

    static func requireUser() throws -> User {
        guard let current else { throw APIError.unauthorized }
        guard let user = current.user else { throw current.tokenProblem ?? .unauthorized }
        return user
    }

    static func requireAdmin() throws -> User {
        let user = try requireUser()
        guard user.isAdmin else { throw APIError.forbidden }
        return user
    }
}
