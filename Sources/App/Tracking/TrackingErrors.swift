import Vapor

/// Maps domain errors to HTTP: unknown things → 404, validation → 422 flash message,
/// TMDB failures → 502.
func respondMappingTrackingErrors(_ req: Request, _ body: () async throws -> HTMLResponse) async throws -> Response {
    do {
        return try await body().encodeResponse(for: req)
    } catch let error as TrackingError {
        switch error {
        case .notFound: throw Abort(.notFound)
        case .futureDate: return try await flashError("Datum liegt in der Zukunft.").encodeResponse(for: req)
        case .invalidDate: return try await flashError("Ungültiges Datum.").encodeResponse(for: req)
        case .notAired: return try await flashError("Folge ist noch nicht erschienen.").encodeResponse(for: req)
        case .invalidRating: return try await flashError("Bewertung muss zwischen 1 und 10 liegen.").encodeResponse(for: req)
        }
    } catch TMDBError.notFound {
        throw Abort(.notFound)
    } catch TMDBError.missingToken {
        return try await flashError(TMDBError.missingToken.description).encodeResponse(for: req)
    } catch let error as TMDBError {
        throw Abort(.badGateway, reason: "TMDB nicht erreichbar: \(error)")
    }
}
