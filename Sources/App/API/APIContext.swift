import Vapor

/// Per-request state of an App API call (set by `APIContextMiddleware`, read by the handlers).
struct APIRequestState: Sendable {
    let request: Request
    let user: User?
    /// Why a presented token was not accepted (unknown or expired).
    let tokenProblem: APIError?
}

/// Task-local access to the current App API request and its authenticated user, for the generated handlers that only
/// receive their operation input.
enum APIContext {
    /// State of the API request being handled; nil outside `APIContextMiddleware`.
    @TaskLocal static var current: APIRequestState?

    /// The Vapor request of the current API call.
    /// - Returns: The request.
    /// - Throws: `APIError` with status 500 (`internal`) when called outside an API request.
    static func request() throws -> Request {
        guard let current else { throw APIError(status: .internalServerError, code: "internal", message: "Interner Fehler.") }
        return current.request
    }

    /// The user authenticated by the request's bearer token.
    /// - Returns: The token's user.
    /// - Throws: `APIError.unauthorized` without a token (or outside an API request), otherwise the token's problem
    ///   (`APIError.unauthorized` for an unknown token, `APIError.tokenExpired` for an expired one).
    static func requireUser() throws -> User {
        guard let current else { throw APIError.unauthorized }
        guard let user = current.user else { throw current.tokenProblem ?? .unauthorized }
        return user
    }

    /// The authenticated user, who must be an admin.
    /// - Returns: The admin user.
    /// - Throws: The errors of `requireUser()`, `APIError.forbidden` for non-admins.
    static func requireAdmin() throws -> User {
        let user = try requireUser()
        guard user.isAdmin else { throw APIError.forbidden }
        return user
    }
}
