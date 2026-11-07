import Vapor

/// Sends unauthenticated requests to the login page; htmx requests get `HX-Redirect`
/// so the whole page navigates instead of a fragment being replaced by the form.
struct AuthRedirectMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.auth.has(User.self) else {
            if request.isHTMX {
                return Response(status: .ok, headers: ["HX-Redirect": "/login"])
            }
            return request.redirect(to: "/login", redirectType: .normal)
        }
        return try await next.respond(to: request)
    }
}
