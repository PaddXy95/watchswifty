import Vapor

/// CSRF protection for state-changing requests: the Origin must match the host the
/// browser talked to; without an Origin header only htmx requests are accepted.
struct OriginCheckMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method != .GET, request.method != .HEAD else {
            return try await next.respond(to: request)
        }
        let host = (request.headers.first(name: "X-Forwarded-Host") ?? request.headers.first(name: .host))?
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let origin = request.headers.first(name: .origin) {
            guard let host, let originHost = Self.hostAndPort(of: origin), originHost == host else {
                throw Abort(.forbidden)
            }
        } else if !request.isHTMX {
            throw Abort(.forbidden)
        }
        return try await next.respond(to: request)
    }

    static func hostAndPort(of origin: String) -> String? {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return nil }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
