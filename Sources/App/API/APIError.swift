import Foundation
import HTTPTypes
import OpenAPIRuntime
import Vapor

/// Error of the App API, rendered as `{"code": …, "message": …}` (schema `Error`). Messages are the web UI's texts.
struct APIError: Error, Sendable, Equatable {
    let status: HTTPStatus
    let code: String
    let message: String

    static let unauthorized = APIError(status: .unauthorized, code: "unauthorized", message: "Nicht angemeldet – bitte die App neu verbinden.")
    static let tokenExpired = APIError(status: .unauthorized, code: "tokenExpired", message: "Die Anmeldung ist abgelaufen – bitte die App neu verbinden.")
    static let forbidden = APIError(status: .forbidden, code: "forbidden", message: "Kein Zugriff.")
    static let notFound = APIError(status: .notFound, code: "notFound", message: "Nicht gefunden.")
    static let invalidGrant = APIError(status: .badRequest, code: "invalidGrant", message: "Der Anmeldecode ist ungültig oder abgelaufen.")
    static let selfAction = APIError(status: .unprocessableEntity, code: "selfAction", message: "Das geht nicht für das eigene Konto.")
    static let noPassword = APIError(status: .conflict, code: "noPassword", message: "Dieses Konto hat kein Passwort.")
    static let payloadTooLarge = APIError(status: .payloadTooLarge, code: "payloadTooLarge", message: "Die Datei ist zu groß.")

    static func mailNotConfigured(_ message: String = MailError.notConfigured.message) -> APIError {
        APIError(status: .unprocessableEntity, code: "mailNotConfigured", message: message)
    }

    /// 503, never 502/504: proxies like Cloudflare replace those with their own page and hide the message.
    static func mailFailed(_ message: String) -> APIError {
        APIError(status: .serviceUnavailable, code: "mailFailed", message: message)
    }

    /// The account's address comes from the OIDC provider (linked account without password).
    static func emailFromProvider(name: String) -> APIError {
        APIError(status: .conflict, code: "emailFromProvider", message: "Die Adresse kommt von \(name) – bitte dort ändern.")
    }

    static func validation(_ message: String) -> APIError {
        APIError(status: .unprocessableEntity, code: "validation", message: message)
    }

    /// Maps any error thrown while answering an API request; reuses the web UI's German messages.
    static func from(_ error: any Error, path: String = "") -> APIError {
        switch error {
        case let error as APIError:
            return error
        case let error as MailError:
            return error == .notConfigured ? .mailNotConfigured() : .mailFailed(error.message)
        case let error as ServerError:
            let inner = from(error.underlyingError, path: path)
            // Request problems found by the generated code (content type, missing body, Accept) keep their 4xx status.
            guard inner.status.code >= 500, (400..<500).contains(error.httpStatus.code) else { return inner }
            let status = HTTPStatus(statusCode: error.httpStatus.code)
            let code: String = switch status.code {
            case 406: "notAcceptable"
            case 413: "payloadTooLarge"
            case 415: "unsupportedMediaType"
            default: "validation"
            }
            return APIError(status: status, code: code, message: "Ungültige Anfrage: \(error.underlyingError.localizedDescription)")
        case TMDBError.missingToken:
            return APIError(status: .unprocessableEntity, code: "missingTMDBToken", message: TMDBError.missingToken.description)
        case TMDBError.notFound:
            return APIError(status: .notFound, code: "notFound", message: "Bei TMDB nicht gefunden.")
        case let error as TMDBError:
            let (_, message) = HTMLErrorMiddleware.describe(error, path: path)
            return APIError(status: .serviceUnavailable, code: "tmdbUnavailable", message: message)
        default:
            let (status, message) = HTMLErrorMiddleware.describe(error, path: path)
            let code: String
            switch status.code {
            case 401: code = "unauthorized"
            case 403: code = "forbidden"
            case 404: code = "notFound"
            case 405: code = "methodNotAllowed"
            case 413: code = "payloadTooLarge"
            case 400..<500: code = "validation"
            default: code = "internal"
            }
            return APIError(status: status, code: code, message: message)
        }
    }

    /// JSON response for this error (401 also announces the bearer scheme).
    func response() -> Response {
        let response = Response(status: status)
        try? response.content.encode(["code": code, "message": message], as: .json)
        if status == .unauthorized { response.headers.replaceOrAdd(name: .wwwAuthenticate, value: "Bearer") }
        return response
    }
}

extension Request {
    /// The App API answers under `/api/v1`; errors there are JSON, not HTML.
    var isAPIRequest: Bool { url.path.hasPrefix("/api/v1/") || url.path == "/api/v1" }
}
