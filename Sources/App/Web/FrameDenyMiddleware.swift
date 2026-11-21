import Vapor

/// No page may be shown inside a frame (clickjacking). `SameSite=Lax` alone does not cover same-site hosts, e.g. another
/// service on the same IP with a different port or under the same home domain.
struct FrameDenyMiddleware: AsyncMiddleware {
    /// Passes the request on and adds `X-Frame-Options: DENY` and `Content-Security-Policy: frame-ancestors 'none'` to the
    /// response.
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - next: The rest of the responder chain.
    /// - Returns: The response of `next` with both headers set (replacing existing values).
    /// - Throws: Whatever `next` throws; in practice nothing, since `HTMLErrorMiddleware` (registered after this one)
    ///   turns errors into responses, which then get the headers too.
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "frame-ancestors 'none'")
        return response
    }
}
