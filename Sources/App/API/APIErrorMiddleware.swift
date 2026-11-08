import OpenAPIRuntime
import Vapor

/// Turns errors of App API handlers into JSON error responses.
struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let apiError = APIError.from(error, path: request.url.path)
            if apiError.status.code >= 500 {
                request.logger.error("\(request.method) \(request.url.path) → \(apiError.status.code): \(Self.logDescription(of: error))")
            }
            return apiError.response()
        }
    }

    /// Log line for an API error. `ServerError`'s own description contains every request header (bearer token,
    /// cookies) and the decoded input (passwords, PKCE verifier), so only the operation and the cause are logged.
    static func logDescription(of error: any Error) -> String {
        if let serverError = error as? ServerError {
            return "\(serverError.operationID): \(logDescription(of: serverError.underlyingError))"
        }
        if let apiError = error as? APIError { return "\(apiError.code): \(apiError.message)" }
        return String(reflecting: error)
    }
}
