import Vapor

/// Restricts a route group to admins.
struct RequireAdminMiddleware: AsyncMiddleware {
    /// Passes requests of admins on.
    /// - Parameters:
    ///   - request: The incoming, authenticated request.
    ///   - next: The rest of the responder chain.
    /// - Returns: The downstream response.
    /// - Throws: `Abort(.forbidden)` for non-admins, `Abort(.unauthorized)` without a signed-in user, or whatever the
    ///   downstream responder throws.
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard try request.currentUser.isAdmin else { throw Abort(.forbidden) }
        return try await next.respond(to: request)
    }
}
