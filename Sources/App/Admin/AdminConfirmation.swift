import Foundation
import Vapor

/// Proof that the acting admin is present, not just their device or session (security audit F10): needed to grant
/// admin rights and to set the password of, or create a linking link for, another admin. Otherwise a stolen admin
/// device could mint or take over a peer admin, who then acts on the owner's own account.
enum AdminConfirmation: Sendable {
    /// Web: confirmed with the password or through the provider within the last five minutes.
    case recent(Bool)
    /// App API: the acting admin's current password from the request.
    case password(String?)

    static let neededMessage = "Bitte zuerst bestätigen, dass du es bist (gilt 5 Minuten)."
    static let passwordNeededMessage = "Zur Bestätigung bitte dein aktuelles Passwort mitschicken."
    static let browserOnlyMessage = "Dein Konto hat kein Passwort – Admin-Rechte bitte im Browser vergeben."
    /// Web session key: when the admin last confirmed with their password (seconds since 1970).
    static let sessionKey = "admin.confirmedAt"

    static func required(_ message: String) -> APIError {
        APIError(status: .forbidden, code: "confirmationRequired", message: message)
    }

    static let browserOnly = APIError(status: .forbidden, code: "confirmInBrowser", message: browserOnlyMessage)
}

extension UserAdminService {
    /// Throws unless `actor` confirmed: on the web within the last five minutes, in the App API with the current
    /// password (accounts without a usable password confirm through the provider, so only in the browser).
    func requireConfirmation(by actor: User, _ confirmation: AdminConfirmation) async throws {
        switch confirmation {
        case let .recent(confirmed):
            guard confirmed else { throw AdminConfirmation.required(AdminConfirmation.neededMessage) }
        case let .password(password):
            guard !actor.isSSOAccount(oidc, passwordLogin: passwordLogin), actor.hasPassword else { throw AdminConfirmation.browserOnly }
            guard let password, !password.isEmpty else { throw AdminConfirmation.required(AdminConfirmation.passwordNeededMessage) }
            guard try await hasher.verify(password, created: actor.passwordHash) else {
                throw AdminConfirmation.required(AccountValidation.wrongCurrentPasswordMessage)
            }
        }
    }
}
