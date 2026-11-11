import Fluent
import Foundation
import Vapor

struct NotificationPassResult: Equatable, Sendable {
    var sent = 0
    var failed = 0
    var cleaned = 0
}

/// Part of the daily pass: one digest per user with something due; recorded only after it went out, so a failure
/// is retried the next day. Users without a channel are skipped quietly (their items wait until one exists).
func runNotifications(db: any Database, notifications: NotificationService, today: String, now: Date = .now,
                      logger: Logger) async -> NotificationPassResult {
    var result = NotificationPassResult()
    let notices = EpisodeNoticeService(db: db)
    let users: [User]
    do {
        users = try await User.query(on: db).group(.or) { group in
            group.filter(\.$notifyAnnounced == true).filter(\.$notifySoon == true).filter(\.$notifyToday == true)
        }.sort(\.$username).all()
    } catch {
        logger.error("Benachrichtigungen: Abfrage fehlgeschlagen: \(error)")
        return result
    }
    for user in users {
        if Task.isCancelled { break }
        do {
            guard try await notifications.activeChannel(for: user) != nil else { continue }
            let due = try await notices.due(for: user, today: today)
            guard !due.isEmpty else { continue }
            let message = NotificationTexts.digest(username: user.username, items: due, today: today,
                                                   baseURL: try await notifications.baseURL())
            do {
                try await notifications.send(message, to: user)
            } catch let error as NotifyError {
                logger.warning("Benachrichtigung für \(user.username) fehlgeschlagen: \(error.message)")
                result.failed += 1
                continue
            }
            try await notices.record(due, userID: user.requireID(), now: now)
            result.sent += 1
        } catch {
            logger.warning("Benachrichtigung für \(user.username) fehlgeschlagen: \(String(describing: type(of: error)))")
            result.failed += 1
        }
    }
    do {
        result.cleaned = try await notices.cleanup(today: today)
    } catch {
        logger.warning("Benachrichtigungen: Aufräumen fehlgeschlagen: \(error)")
    }
    return result
}
