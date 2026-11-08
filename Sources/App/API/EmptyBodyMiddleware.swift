import HTTPTypes
import OpenAPIRuntime

/// OpenAPIVapor always hands the generated code a body, even for requests without one, so optional JSON bodies
/// (e.g. `POST /v1/tv/{id}/seasons/{n}/watch`) would fail to decode. Requests with `Content-Length: 0`, or with
/// neither a length nor chunked encoding, get no body.
struct EmptyBodyMiddleware: ServerMiddleware {
    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var body = body
        switch body?.length {
        case .known(let length) where length == 0:
            body = nil
        case .unknown where request.headerFields[.transferEncoding] == nil:
            body = nil
        default:
            break
        }
        return try await next(request, body, metadata)
    }
}
