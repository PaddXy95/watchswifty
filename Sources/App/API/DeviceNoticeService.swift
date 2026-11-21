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

    /// Sends the „Neues Gerät verbunden“ (new device connected) notice to the user's active channel; failures are
    /// logged.
    /// - Parameters:
    ///   - userID: The account that got the device token.
    ///   - deviceName: The device name the app sent.
    ///   - now: The connection time shown in the notice.
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
    /// The device notice service on the application's database and channels (it runs after the response).
    var deviceNotice: DeviceNoticeService {
        DeviceNoticeService(db: application.db, notifications: application.notifications, logger: application.logger)
    }
}

extension Application {
    /// The device notice service for code without a request.
    var deviceNotice: DeviceNoticeService {
        DeviceNoticeService(db: db, notifications: notifications, logger: logger)
    }
}
