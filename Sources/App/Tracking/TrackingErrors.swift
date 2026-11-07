import Vapor

/// Encodes the page/fragment; domain errors (TrackingError, TMDBError, Abort) propagate to
/// `HTMLErrorMiddleware`, which renders them as German flash messages or error pages.
func respondMappingTrackingErrors(_ req: Request, _ body: () async throws -> HTMLResponse) async throws -> Response {
    try await body().encodeResponse(for: req)
}
