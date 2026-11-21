import Fluent
import Vapor

/// `App link-oidc <benutzer>`: emergency exit when an account cannot get in through the provider any more (changed
/// `sub`, password login switched off too early). Removes the link and prints a one-time link valid for an hour.
struct LinkOIDCCommand: AsyncCommand {
    /// Command-line arguments: the username (`benutzer`).
    struct Signature: CommandSignature {
        @Argument(name: "benutzer", help: "Benutzername")
        var username: String
    }

    /// German help text shown in the command list.
    var help: String { "Löst die OIDC-Verknüpfung eines Kontos und gibt einen Verknüpfungslink aus (1 Stunde gültig)." }

    /// Unlinks the account and prints `<canonical origin>/auth/oidc/start?link=<token>`.
    /// - Parameters:
    ///   - context: The command context (application and console).
    ///   - signature: The parsed arguments.
    /// - Throws: `CommandFailure` when OIDC is not configured or the user does not exist; database errors otherwise.
    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let oidc = app.loginSettings.current.oidc else { throw CommandFailure(OIDCCommandText.notConfigured) }
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

/// `App oidc-move-issuer <alt> <neu>`: the provider's address changed (new domain, renamed slug) but the `sub` values
/// stayed the same – moves every link to the new issuer.
struct MoveOIDCIssuerCommand: AsyncCommand {
    /// Command-line arguments: the old issuer (`alt`) and the new one (`neu`).
    struct Signature: CommandSignature {
        @Argument(name: "alt", help: "Bisheriger Issuer")
        var from: String
        @Argument(name: "neu", help: "Neuer Issuer (genau wie in der Discovery)")
        var to: String
    }

    /// German help text shown in the command list.
    var help: String { "Schreibt die OIDC-Verknüpfungen aller Konten von einem Issuer auf einen neuen um." }

    /// Warns when the discovery names a different issuer (or cannot be reached), then moves the links and prints how
    /// many accounts changed.
    /// - Parameters:
    ///   - context: The command context (application and console).
    ///   - signature: The parsed arguments.
    /// - Throws: `CommandFailure` when OIDC is not configured or the move would create duplicate identities; database
    ///   errors otherwise.
    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let oidc = app.loginSettings.current.oidc else { throw CommandFailure(OIDCCommandText.notConfigured) }
        do {
            let provider = app.oidcProviders.provider(for: oidc)
            if let discovered = try? await provider.discoveredIssuer() {
                if discovered != signature.to {
                    context.console.print("Achtung: Die Discovery nennt den Issuer \(discovered) – nicht \(signature.to). Anmeldungen klappen nur, wenn beides genau übereinstimmt.")
                }
            } else {
                context.console.print("Hinweis: Discovery nicht erreichbar – der neue Issuer wurde nicht geprüft.")
            }
        }
        let service = OIDCLoginService(db: app.db, cipher: app.tokenCipher, oidc: oidc, passwordLogin: app.loginSettings.current.passwordLogin,
                                       lock: app.oidcIdentityLock)
        let moved: Int
        do {
            moved = try await service.moveIssuer(from: signature.from, to: signature.to)
        } catch let error as APIError {
            throw CommandFailure(error.message)
        }
        if moved == 0 {
            context.console.print("Keine Konten mit Issuer \(signature.from) gefunden.")
        } else {
            context.console.print("\(moved) \(moved == 1 ? "Konto" : "Konten") auf \(signature.to) umgestellt.")
        }
    }
}

/// German texts shared by the OIDC commands.
enum OIDCCommandText {
    static let notConfigured = "OIDC ist nicht eingerichtet – unter Admin → System → Anmeldung über OIDC (SSO) einrichten."
}
