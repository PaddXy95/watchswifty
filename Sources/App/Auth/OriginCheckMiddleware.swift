import Foundation
import Vapor

/// CSRF protection for state-changing requests: the Origin must match the host the browser
/// talked to (Host / X-Forwarded-Host [+ X-Forwarded-Port]) or one of the configured
/// `PUBLIC_ORIGIN`s; without an Origin header only htmx requests are accepted.
struct OriginCheckMiddleware: AsyncMiddleware {
    let allowedOrigins: Set<String>

    init(allowedOrigins: [String] = []) {
        self.allowedOrigins = Set(allowedOrigins.map(Self.normalizeOrigin))
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // The App API authenticates with bearer tokens only (no cookies), so cross-site requests cannot act as a user.
        guard request.method != .GET, request.method != .HEAD, !request.isAPIRequest else {
            return try await next.respond(to: request)
        }
        if let origin = request.headers.first(name: .origin) {
            guard allowedOrigins.contains(Self.normalizeOrigin(origin)) || matchesRequestHost(origin, request) else {
                throw Abort(.forbidden, reason: "Anfrage abgelehnt: Herkunft passt nicht zur Adresse.")
            }
        } else if !request.isHTMX {
            throw Abort(.forbidden, reason: "Anfrage abgelehnt: Herkunft fehlt.")
        }
        return try await next.respond(to: request)
    }

    private func matchesRequestHost(_ origin: String, _ request: Request) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), let originHost = url.host?.lowercased() else {
            return false
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let originAuthority = Self.authority(host: originHost, port: url.port, defaultPort: defaultPort)

        let forwardedHost = request.headers.first(name: "X-Forwarded-Host")?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let rawHost = forwardedHost ?? request.headers.first(name: .host)?.lowercased()
        guard var host = rawHost, !host.isEmpty else { return false }
        if forwardedHost != nil, !host.contains(":"), let port = request.headers.first(name: "X-Forwarded-Port").flatMap({ Int($0) }) {
            host += ":\(port)"
        }
        // Compare without default ports on either side.
        let parts = host.split(separator: ":", maxSplits: 1)
        let requestAuthority = Self.authority(host: String(parts[0]), port: parts.count > 1 ? Int(parts[1]) : nil, defaultPort: defaultPort)
        return originAuthority == requestAuthority
    }

    private static func authority(host: String, port: Int?, defaultPort: Int) -> String {
        guard let port, port != defaultPort else { return host }
        return "\(host):\(port)"
    }

    /// `scheme://host[:port]`, lowercased, without trailing slash.
    static func normalizeOrigin(_ origin: String) -> String {
        var value = origin.trimmingCharacters(in: .whitespaces).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
