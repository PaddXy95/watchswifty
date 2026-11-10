import Elementary
import Vapor

/// Turns every error into German HTML: a flash message (retargeted to `#flash`) for htmx
/// requests, a small error page otherwise. Replaces Vapor's JSON ErrorMiddleware.
struct HTMLErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            if request.isAPIRequest {
                let apiError = APIError.from(error, path: request.url.path)
                if apiError.status.code >= 500 {
                    request.logger.error("\(request.method) \(request.url.path) → \(apiError.status.code): \(APIErrorMiddleware.logDescription(of: error))")
                }
                return apiError.response()
            }
            let (status, message) = Self.describe(error, path: request.url.path)
            if status.code >= 500 {
                request.logger.error("\(request.method) \(request.url.path) → \(status.code): \(String(reflecting: error))")
            } else {
                request.logger.debug("\(request.method) \(request.url.path) → \(status.code): \(message)")
            }
            if request.isHTMX {
                return try await flashError(message, status: status).encodeResponse(for: request)
            }
            return try await HTMLResponse(status: status, ErrorPage(status: status, message: message)).encodeResponse(for: request)
        }
    }

    static func describe(_ error: any Error, path: String) -> (HTTPStatus, String) {
        switch error {
        case let error as APIError:
            return (error.status, error.message)
        case let error as TrackingError:
            switch error {
            case .notFound: return (.notFound, "Nicht gefunden.")
            case .futureDate: return (.unprocessableEntity, "Datum liegt in der Zukunft.")
            case .invalidDate: return (.unprocessableEntity, "Ungültiges Datum.")
            case .notAired: return (.unprocessableEntity, "Folge ist noch nicht erschienen.")
            case .invalidRating: return (.unprocessableEntity, "Bewertung muss zwischen 1 und 10 liegen.")
            case .commentTooLong: return (.unprocessableEntity, "Kommentar darf höchstens 2.000 Zeichen haben.")
            }
        case let error as TMDBError:
            switch error {
            case .notFound: return (.notFound, "Bei TMDB nicht gefunden.")
            case .missingToken: return (.unprocessableEntity, error.description)
            case .unauthorized: return (.unprocessableEntity, "TMDB hat deinen Token abgelehnt – bitte unter Konto erneuern.")
            // 503, not 502: proxies like Cloudflare replace a 502 with their own page and hide this message.
            default: return (.serviceUnavailable, "TMDB nicht erreichbar: \(error)")
            }
        case let abort as any AbortError:
            let status = abort.status
            let custom = abort.reason != status.reasonPhrase ? abort.reason : nil
            switch status.code {
            case 404: return (status, custom ?? "Nicht gefunden.")
            case 403:
                let base = custom ?? "Kein Zugriff."
                if base.contains("Herkunft") {
                    return (status, base + " Läuft WatchSwifty hinter einem Reverse-Proxy? Dann PUBLIC_ORIGIN setzen (siehe README).")
                }
                return (status, base)
            case 413 where path.hasPrefix("/import"):
                return (status, "Die Datei ist zu groß (höchstens 10 MB). Bitte die Datei NetflixViewingHistory.csv aus „Wiedergabeaktivität“ hochladen.")
            case 413: return (status, "Die Anfrage ist zu groß.")
            case 400..<500: return (status, custom ?? "Ungültige Anfrage.")
            default: return (status, custom ?? "Interner Fehler.")
            }
        default:
            return (.internalServerError, "Interner Fehler.")
        }
    }
}

struct ErrorPage: HTML {
    let status: HTTPStatus
    let message: String

    var body: some HTML {
        PageLayout(title: "Fehler \(status.code)", nav: nil) {
            h1 { "Fehler \(status.code)" }
            p(.class("error"), .custom(name: "role", value: "alert")) { message }
            p { a(.href("/")) { "Zur Startseite" } }
        }
    }
}
