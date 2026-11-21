import Fluent
import Foundation
import Vapor

/// Counters of one ``refreshWatchLaterAvailability(db:provider:cipher:logger:now:)`` pass, logged by the daily pass.
struct AvailabilityPassResult: Equatable, Sendable {
    /// Titles whose offers were fetched and reconciled.
    var refreshed = 0
    /// Titles whose fetch or reconciliation failed.
    var failed = 0
    /// Titles whose stored offers were deleted after 30 days without a fetch.
    var expired = 0
}

/// Part of the daily pass (spec §4.2): every title on any „Später ansehen“ list once (the answer covers all countries),
/// with the tokens of its list users in turn; known offers are reconciled after each fetch; then data older than 30 days
/// is deleted.
///
/// Titles none of whose list users has a TMDB token are skipped; when every token is rejected, the title counts as
/// failed. Per-title failures are logged and counted; other errors are logged and end the pass early. The loop stops
/// when the task is cancelled.
/// - Parameters:
///   - db: The database.
///   - provider: Creates TMDB clients for user tokens.
///   - cipher: Decrypts the users' stored TMDB tokens.
///   - logger: Receives warnings and errors.
///   - now: The fetch time and the reference for the 30-day expiry.
/// - Returns: How many titles were refreshed, failed and expired.
func refreshWatchLaterAvailability(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger,
                                   now: Date = .now) async -> AvailabilityPassResult {
    var result = AvailabilityPassResult()
    let availability = AvailabilityService(db: db)
    let notices = AvailabilityNoticeService(db: db)
    do {
        let entries = try await WatchLaterEntry.query(on: db).all()
        let usersByTitle = Dictionary(grouping: entries, by: \.$title.id).mapValues { $0.map(\.$user.id) }
        for (titleID, userIDs) in usersByTitle.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if Task.isCancelled { break }
            guard let title = try await Title.find(titleID, on: db) else { continue }
            let tokens = try await User.query(on: db).filter(\.$id ~~ Array(Set(userIDs))).filter(\.$tmdbToken != nil)
                .sort(\.$username).all().compactMap { cipher.open($0.tmdbToken) }
            do {
                guard try await withAcceptedToken(tokens, { try await availability.refresh(title, tmdb: provider.make($0), now: now) })
                else { continue }
                try await notices.reconcile(titleID: titleID, now: now)
                result.refreshed += 1
            } catch {
                logger.warning("Verfügbarkeit für \(title.name) nicht abgefragt: \(error)")
                result.failed += 1
            }
        }
        result.expired = try await availability.expire(now: now)
    } catch {
        logger.error("Verfügbarkeit: Durchgang fehlgeschlagen: \(error)")
    }
    return result
}
