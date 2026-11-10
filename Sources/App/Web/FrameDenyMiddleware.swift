import Vapor

/// No page may be shown inside a frame (clickjacking). `SameSite=Lax` alone does not cover same-site hosts, e.g. another
/// service on the same IP with a different port or under the same home domain.
struct FrameDenyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "frame-ancestors 'none'")
        return response
    }
}
