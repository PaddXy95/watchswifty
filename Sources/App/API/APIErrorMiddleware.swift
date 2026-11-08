import Vapor

/// Turns errors of App API handlers into JSON error responses.
struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let apiError = APIError.from(error, path: request.url.path)
            if apiError.status.code >= 500 {
                request.logger.error("\(request.method) \(request.url.path) → \(apiError.status.code): \(String(reflecting: error))")
            }
            return apiError.response()
        }
    }
}
