import Fluent
import Foundation
import Vapor

/// „Neues Gerät verbunden“: tells the account owner (by their notification channel) when an app got a device token
/// through the browser login, so a connection the owner did not start (e.g. another app posing as WatchSwifty) does not
/// go unnoticed. Runs after the response and never throws; without a channel nothing happens.
struct DeviceNoticeService {
    let db: any Database
    let notifications: NotificationService
    let logger: Logger

    func handle(userID: UUID, deviceName: String, now: Date = .now) async {
        var who = userID.uuidString
        do {
            guard let user = try await User.find(userID, on: db) else { return }
            who = user.username
            guard try await notifications.activeChannel(for: user) != nil else { return }
            let link = try await notifications.baseURL().map { "\($0)/account" }
            try await notifications.send(NotificationTexts.newDevice(username: user.username, device: deviceName, at: now, link: link),
                                         to: user)
        } catch let error as NotifyError {
            logger.warning("Geräte-Hinweis für \(who) fehlgeschlagen: \(error.message)")
        } catch {
            logger.warning("Geräte-Hinweis für \(who) fehlgeschlagen: \(String(describing: type(of: error)))")
        }
    }
}

extension Request {
    var deviceNotice: DeviceNoticeService {
        DeviceNoticeService(db: application.db, notifications: application.notifications, logger: application.logger)
    }
}

extension Application {
    var deviceNotice: DeviceNoticeService {
        DeviceNoticeService(db: db, notifications: notifications, logger: logger)
    }
}
