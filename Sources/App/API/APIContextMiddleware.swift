import Fluent
import Vapor

/// Resolves the bearer token (session cookies are ignored) and makes the request available to the handlers.
struct APIContextMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        var user: User?
        var problem: APIError?
        if let bearer = request.headers.bearerAuthorization?.token {
            do {
                user = try await APITokenService(db: request.db).authenticate(bearer)
                // Shared code (req.tmdb, req.userID, services) sees the token's user; nothing is stored in the session.
                if let user { request.auth.login(user) }
            } catch let error as APIError {
                problem = error
            }
        }
        let state = APIRequestState(request: request, user: user, tokenProblem: problem)
        return try await APIContext.$current.withValue(state) {
            try await next.respond(to: request)
        }
    }
}
