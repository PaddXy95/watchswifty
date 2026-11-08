import HTTPTypes
import OpenAPIRuntime

/// OpenAPIVapor streams request bodies and the generated code collects JSON bodies without a limit – before the
/// handler (and its token check) runs. This caps every body: 1 MB for JSON, more for the two uploads.
struct BodyLimitMiddleware: ServerMiddleware {
    static let defaultLimit = 1024 * 1024
    static let limits = ["uploadNetflix": 11 * 1024 * 1024, "uploadFilmList": 3 * 1024 * 1024]

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let body else { return try await next(request, nil, metadata) }
        let limit = Self.limits[operationID] ?? Self.defaultLimit
        if case .known(let length) = body.length, length > limit { throw APIError.payloadTooLarge }
        let limited = HTTPBody(LimitedBytes(base: body, limit: limit), length: body.length, iterationBehavior: body.iterationBehavior)
        return try await next(request, limited, metadata)
    }
}

/// Passes chunks through and throws `payloadTooLarge` once more than `limit` bytes arrived.
struct LimitedBytes: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk
    let base: HTTPBody
    let limit: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: HTTPBody.AsyncIterator
        let limit: Int
        var count = 0

        mutating func next() async throws -> HTTPBody.ByteChunk? {
            guard let chunk = try await base.next() else { return nil }
            count += chunk.count
            guard count <= limit else { throw APIError.payloadTooLarge }
            return chunk
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), limit: limit)
    }
}
