import HTTPTypes
import OpenAPIRuntime

/// OpenAPIVapor streams request bodies and the generated code collects JSON bodies without a limit – before the
/// handler (and its token check) runs. This caps every body: 1 MB for JSON, more for the two uploads.
struct BodyLimitMiddleware: ServerMiddleware {
    /// Limit in bytes for every operation not listed in `limits` (1 MB).
    static let defaultLimit = 1024 * 1024
    /// Larger limits in bytes per operation ID (the Netflix and the standard import upload).
    static let limits = ["uploadNetflix": 11 * 1024 * 1024, "uploadStandardImport": 6 * 1024 * 1024]

    /// Rejects a body whose announced length exceeds the operation's limit and wraps the rest in `LimitedBytes`.
    /// - Parameters:
    ///   - request: The HTTP request.
    ///   - body: The streamed request body, if any.
    ///   - metadata: Path and query metadata of the request.
    ///   - operationID: The operation being called; selects the limit.
    ///   - next: The next middleware or the handler.
    /// - Returns: The response of `next`.
    /// - Throws: `APIError.payloadTooLarge` for a too large announced length, whatever `next` throws.
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

    /// Iterator that counts the bytes passed through.
    struct AsyncIterator: AsyncIteratorProtocol {
        var base: HTTPBody.AsyncIterator
        let limit: Int
        var count = 0

        /// The next chunk of the body, or nil at its end.
        /// - Returns: The chunk.
        /// - Throws: `APIError.payloadTooLarge` once more than `limit` bytes arrived, errors of the underlying body.
        mutating func next() async throws -> HTTPBody.ByteChunk? {
            guard let chunk = try await base.next() else { return nil }
            count += chunk.count
            guard count <= limit else { throw APIError.payloadTooLarge }
            return chunk
        }
    }

    /// Creates an iterator over the wrapped body that enforces `limit`.
    /// - Returns: The iterator.
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), limit: limit)
    }
}
