import Fluent
import Foundation
import Vapor

/// „Neues Gerät verbunden“: mails the account owner when an app got a device token through the browser login, so a
/// connection the owner did not start (e.g. another app posing as WatchSwifty) does not go unnoticed. Runs after the
/// response and never throws; without an address or mail settings nothing happens.
struct DeviceNoticeService {
    let db: any Database
    let cipher: TokenCipher
    let mail: MailService
    let logger: Logger

    func handle(userID: UUID, deviceName: String, now: Date = .now) async {
        var who = userID.uuidString
        do {
            guard let user = try await User.find(userID, on: db) else { return }
            who = user.username
            guard let address = user.emailState(cipher).address, let settings = try await mail.settings.state().settings else { return }
            try await mail.send(MailTexts.newDevice(to: address, username: user.username, device: deviceName, at: now,
                                                    link: settings.accountLink), now: now)
        } catch let error as MailError {
            logger.warning("Geräte-Mail für \(who) fehlgeschlagen: \(error.message)")
        } catch {
            logger.warning("Geräte-Mail für \(who) fehlgeschlagen: \(String(describing: type(of: error)))")
        }
    }
}

extension Request {
    var deviceNotice: DeviceNoticeService {
        DeviceNoticeService(db: application.db, cipher: application.tokenCipher, mail: application.mail, logger: application.logger)
    }
}
