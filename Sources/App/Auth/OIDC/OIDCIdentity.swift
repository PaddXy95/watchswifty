import Foundation

/// The part of a verified ID token WatchSwifty uses.
struct OIDCIdentity: Codable, Sendable, Equatable {
    var issuer: String
    var subject: String
    var preferredUsername: String?
    var email: String?
    var name: String?
}

/// Why an OIDC sign-in failed. `logReason` is for the log only and never contains a code or token.
enum OIDCError: Error, Equatable {
    case unreachable
    case denied
    case failed(logReason: String)
    /// The provider signs ID tokens with HS* (Authentik without signing key) – rejected.
    case symmetricSigning
    case misconfigured(logReason: String)
    /// The token names a key the current JWKS does not contain (the provider may have rotated keys).
    case unknownKey(kid: String?)

    /// Message for the login page (spec „Fehlerfälle“); `name` is `OIDC_NAME`.
    func message(name: String) -> String {
        switch self {
        case .unreachable: "\(name) ist gerade nicht erreichbar."
        case .denied: "\(name) hat die Anmeldung abgelehnt."
        case .failed, .symmetricSigning, .misconfigured, .unknownKey: "Anmeldung über \(name) fehlgeschlagen."
        }
    }

    /// Text for admins (System page, API): the cause, never a code or token.
    func adminDescription(name: String) -> String {
        switch self {
        case .unreachable: "\(name) ist nicht erreichbar."
        case .denied: "\(name) hat abgelehnt."
        default: logDescription
        }
    }

    /// Text for the log.
    var logDescription: String {
        switch self {
        case .unreachable: "Provider nicht erreichbar"
        case .denied: "Provider hat abgelehnt"
        case .failed(let reason): reason
        case .symmetricSigning:
            "Der Provider signiert ID-Tokens symmetrisch (HS*) – beim Provider einen asymmetrischen Signaturschlüssel einstellen (Authentik: beim Provider einen Signing Key wählen)."
        case .misconfigured(let reason): reason
        case .unknownKey(let kid): "Unbekannter Schlüssel im ID-Token (kid \(kid ?? "–"))"
        }
    }
}
