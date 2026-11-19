import Fluent
import Foundation
import Vapor

/// „Passwort vergessen“: mails a reset link when the account has a password and a readable address. Runs after the
/// response (never throws), so neither the answer nor its timing reveals whether the account exists.
struct ForgotPasswordService {
    /// At most one reset mail per user in this many seconds.
    static let throttle: TimeInterval = 300

    let db: any Database
    let cipher: TokenCipher
    let mail: MailService
    let logger: Logger
    /// App-wide lock: the throttle check and issuing the token run as one step, so parallel requests send one mail.
    let lock: AsyncMutex

    func handle(username raw: String, now: Date = .now) async {
        let username = User.normalize(raw)
        do {
            guard let user = try await User.query(on: db).filter(\.$username == username).first(), user.hasPassword,
                  let address = user.emailState(cipher).address,
                  let settings = try await mail.settings.state().settings else { return }
            let tokens = PasswordTokenService(db: db)
            let userID = try user.requireID()
            let issued: String? = try await lock.withLock {
                if let last = try await tokens.latest(userID: userID, purpose: .reset),
                   now.timeIntervalSince(last.createdAt) < Self.throttle { return nil }
                return try await tokens.issue(userID: userID, purpose: .reset, now: now)
            }
            guard let token = issued else { return }
            try await mail.send(MailTexts.reset(to: address, username: user.username, link: settings.link(token: token)), now: now)
        } catch let error as MailError {
            logger.warning("Passwort-Mail für \(username) fehlgeschlagen: \(error.message)")
        } catch {
            logger.warning("Passwort-Mail für \(username) fehlgeschlagen: \(String(describing: type(of: error)))")
        }
    }
}

extension Request {
    var forgotPassword: ForgotPasswordService {
        ForgotPasswordService(db: application.db, cipher: application.tokenCipher, mail: application.mail, logger: application.logger,
                              lock: application.forgotPasswordLock)
    }
}
