import Vapor

/// Encodes the page/fragment; domain errors (TrackingError, TMDBError, Abort) propagate to
/// `HTMLErrorMiddleware`, which renders them as German flash messages or error pages.
/// - Parameters:
///   - req: The current request, used to encode the response.
///   - body: Builds the HTML page or fragment to send.
/// - Returns: The encoded response.
/// - Throws: Whatever `body` throws (`TrackingError`, `TMDBError`, `Abort`, …), unchanged.
func respondMappingTrackingErrors(_ req: Request, _ body: () async throws -> HTMLResponse) async throws -> Response {
    try await body().encodeResponse(for: req)
}
