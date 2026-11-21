import Fluent
import Foundation
import Vapor

struct AvailabilityPassResult: Equatable, Sendable {
    var refreshed = 0
    var failed = 0
    var expired = 0
}

/// Part of the daily pass (spec §4.2): every title on any „Später ansehen“ list once (the answer covers all countries),
/// with the tokens of its list users in turn; known offers are reconciled after each fetch; then data older than 30 days
/// is deleted.
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
