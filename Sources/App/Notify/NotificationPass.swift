import Fluent
import Foundation
import Vapor

/// Counters of one ``runNotifications(db:notifications:today:now:logger:)`` pass, logged by the daily pass.
struct NotificationPassResult: Equatable, Sendable {
    /// Digests sent and recorded.
    var sent = 0
    /// Users whose digest could not be sent or recorded.
    var failed = 0
    /// Old sent-notice records deleted.
    var cleaned = 0
}

/// Part of the daily pass: one digest per user with something due (episodes and „Später ansehen“ availability); recorded only after it went out, so a failure
/// is retried the next day. Users without a channel are skipped quietly (their items wait until one exists).
///
/// Ends with ``EpisodeNoticeService/cleanup(today:)``. Errors are logged, never thrown; the loop stops when the task is
/// cancelled.
/// - Parameters:
///   - db: The database.
///   - notifications: Sends the digests.
///   - today: Today as `YYYY-MM-DD`.
///   - now: The sending time recorded on the notices.
///   - logger: Receives warnings and errors.
/// - Returns: How many digests were sent and failed, and how many old records were cleaned up.
func runNotifications(db: any Database, notifications: NotificationService, today: String, now: Date = .now,
                      logger: Logger) async -> NotificationPassResult {
    var result = NotificationPassResult()
    let notices = EpisodeNoticeService(db: db)
    let availability = AvailabilityNoticeService(db: db)
    let users: [User]
    do {
        users = try await User.query(on: db).group(.or) { group in
            group.filter(\.$notifyAnnounced == true).filter(\.$notifySoon == true).filter(\.$notifyToday == true)
                .filter(\.$notifyAvailable == true)
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
            let available = user.notifyAvailable == true ? try await availability.due(userID: user.requireID()) : []
            guard !due.isEmpty || !available.isEmpty else { continue }
            let message = NotificationTexts.digest(username: user.username, items: due, available: available, today: today,
                                                   baseURL: try await notifications.baseURL())
            do {
                try await notifications.send(message, to: user)
            } catch let error as NotifyError {
                logger.warning("Benachrichtigung für \(user.username) fehlgeschlagen: \(error.message)")
                result.failed += 1
                continue
            }
            try await notices.record(due, userID: user.requireID(), now: now)
            try await availability.markSent(available)
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
