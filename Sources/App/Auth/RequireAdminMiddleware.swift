import Vapor

struct RequireAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard try request.currentUser.isAdmin else { throw Abort(.forbidden) }
        return try await next.respond(to: request)
    }
}
