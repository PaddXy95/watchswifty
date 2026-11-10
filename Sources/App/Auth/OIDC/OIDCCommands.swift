import Fluent
import Vapor

/// `App link-oidc <benutzer>`: emergency exit when an account cannot get in through the provider any more (changed
/// `sub`, password login switched off too early). Removes the link and prints a one-time link valid for an hour.
struct LinkOIDCCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "benutzer", help: "Benutzername")
        var username: String
    }

    var help: String { "Löst die OIDC-Verknüpfung eines Kontos und gibt einen Verknüpfungslink aus (1 Stunde gültig)." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let oidc = app.appConfig.oidc else { throw CommandFailure(OIDCCommandText.notConfigured) }
        let username = User.normalize(signature.username)
        guard let user = try await User.query(on: app.db).filter(\.$username == username).first() else {
            throw CommandFailure("Benutzer „\(username)“ gibt es nicht.")
        }
        user.oidcIssuer = nil
        user.oidcSubject = nil
        try await user.save(on: app.db)
        let token = try await OIDCLinkTokenService(db: app.db).issue(userID: try user.requireID(), lifetime: OIDCLinkTokenService.commandLifetime)
        context.console.print("Verknüpfungslink für \(username) (1 Stunde gültig): \(oidc.canonicalOrigin)/auth/oidc/start?link=\(token)")
    }
}

enum OIDCCommandText {
    static let notConfigured = "OIDC ist nicht eingerichtet (OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET)."
}
