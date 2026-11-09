import Fluent
import Vapor

/// A command error with a German message for the operator; the entrypoint prints it and exits with code 1.
struct CommandFailure: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `App reset-password <benutzer>`: sets a new password from the server's shell when nobody can log in anymore
/// (e.g. the only admin forgot theirs). The password is asked twice and hidden, so it never lands in the shell
/// history or the `.env`.
struct ResetPasswordCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "benutzer", help: "Benutzername")
        var username: String
    }

    var help: String { "Setzt das Passwort eines Benutzers neu (fragt es verdeckt ab)." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let username = User.normalize(signature.username)
        guard let user = try await User.query(on: app.db).filter(\.$username == username).first() else {
            throw CommandFailure("Benutzer „\(username)“ gibt es nicht.")
        }
        let password = context.console.ask("Neues Passwort für \(username):".consoleText(), isSecure: true)
        if let error = AccountValidation.passwordError(password) { throw CommandFailure(error) }
        guard context.console.ask("Neues Passwort wiederholen:".consoleText(), isSecure: true) == password else {
            throw CommandFailure("Die Passwörter stimmen nicht überein – nichts geändert.")
        }
        user.passwordHash = try await app.password.async.hash(password)
        try await user.save(on: app.db)
        try await PasswordTokenService(db: app.db).deleteAll(userID: user.requireID())
        context.console.print("Passwort für \(username) geändert.")
    }
}
