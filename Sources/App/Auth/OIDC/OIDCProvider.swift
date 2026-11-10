import Foundation
import NIOCore
import Vapor

/// The OpenID Connect provider as WatchSwifty uses it; `LiveOIDCProvider` in production, a fake in tests.
/// All methods throw only `OIDCError`.
protocol OIDCProvider: Sendable {
    /// The `authorization_endpoint` with all parameters; loads the discovery when needed.
    func authorizationURL(state: String, nonce: String, codeChallenge: String) async throws -> URL
    /// Exchanges the code and returns the verified identity.
    func exchange(code: String, codeVerifier: String, nonce: String) async throws -> OIDCIdentity
    /// `issuer` of the current discovery (for `oidc-move-issuer`).
    func discoveredIssuer() async throws -> String
}

/// The fields of `.well-known/openid-configuration` WatchSwifty needs.
struct OIDCDiscovery: Decodable, Sendable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let jwksURI: String
    let tokenEndpointAuthMethodsSupported: [String]?
    let idTokenSigningAlgValuesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}

/// HTTP for the provider; network failures throw `OIDCError.unreachable`.
protocol OIDCTransport: Sendable {
    func get(_ url: URL) async throws -> (status: UInt, body: Data)
    /// `basicAuth` values are used as given (already form-encoded, RFC 6749 §2.3.1).
    func postForm(_ url: URL, fields: [String: String], basicAuth: (user: String, password: String)?) async throws -> (status: UInt, body: Data)
}

/// `OIDCTransport` over Vapor's HTTP client, 10 seconds per request.
struct VaporOIDCTransport: OIDCTransport {
    let client: any Client
    static let timeout: TimeAmount = .seconds(10)

    func get(_ url: URL) async throws -> (status: UInt, body: Data) {
        do {
            let response = try await client.get(URI(string: url.absoluteString), headers: ["Accept": "application/json"]) { request in
                request.timeout = Self.timeout
            }
            return (response.status.code, response.body.map { Data($0.readableBytesView) } ?? Data())
        } catch {
            throw OIDCError.unreachable
        }
    }

    func postForm(_ url: URL, fields: [String: String], basicAuth: (user: String, password: String)?) async throws -> (status: UInt, body: Data) {
        var headers: HTTPHeaders = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"]
        if let basicAuth {
            headers.replaceOrAdd(name: .authorization,
                                 value: "Basic " + Data("\(basicAuth.user):\(basicAuth.password)".utf8).base64EncodedString())
        }
        let body = fields.sorted { $0.key < $1.key }.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&")
        do {
            let response = try await client.post(URI(string: url.absoluteString), headers: headers) { request in
                request.body = ByteBuffer(string: body)
                request.timeout = Self.timeout
            }
            return (response.status.code, response.body.map { Data($0.readableBytesView) } ?? Data())
        } catch {
            throw OIDCError.unreachable
        }
    }
}

/// `application/x-www-form-urlencoded` encoding of one value (space → `+`).
func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
    allowed.insert(charactersIn: "-._*")
    return value.addingPercentEncoding(withAllowedCharacters: allowed.union(.init(charactersIn: " ")))?
        .replacingOccurrences(of: " ", with: "+") ?? value
}
