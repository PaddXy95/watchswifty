import Fluent
import Foundation
import Vapor

/// A user's country and streaming services (Konto → Streamingdienste).
struct StreamingSettings: Sendable, Equatable {
    let region: String
    let providerIDs: Set<Int>
}

/// Konto → Streamingdienste and `/v1/me/streaming-services` (spec §2).
struct StreamingSettingsService {
    static let regionMessage = "Unbekanntes Land."
    static let providersMessage = "Ungültige Auswahl der Streamingdienste."
    static let maxProviders = 200

    let db: any Database

    func settings(user: User) async throws -> StreamingSettings {
        StreamingSettings(region: user.region,
                          providerIDs: try await AvailabilityNoticeService(db: db).serviceIDs(userID: user.requireID()))
    }

    /// Replaces country and services. Any change re-baselines the user's list, so titles already running at a new service
    /// or in the new country are not reported. Returns whether the country changed.
    func save(user: User, region: String, providerIDs: [Int]) async throws -> Bool {
        guard region.count == 2, region.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw APIError.validation(Self.regionMessage)
        }
        let ids = Set(providerIDs)
        guard ids.count <= Self.maxProviders, ids.allSatisfy({ $0 > 0 }) else { throw APIError.validation(Self.providersMessage) }
        let userID = try user.requireID()
        let current = try await settings(user: user)
        guard current != StreamingSettings(region: region, providerIDs: ids) else { return false }
        try await db.transaction { db in
            try await UserStreamingService.query(on: db).filter(\.$user.$id == userID).delete()
            for id in ids.sorted() { try await UserStreamingService(userID: userID, providerID: id).create(on: db) }
            user.watchRegion = region
            try await user.save(on: db)
            try await AvailabilityNoticeService(db: db).rebaseline(userID: userID)
        }
        return current.region != region
    }

    /// Fetches the list titles whose stored offers do not cover `region` (after a change of country), then reconciles.
    func fetchMissing(userID: UUID, region: String, tmdb: any TMDBClient, logger: Logger) async {
        do {
            let entries = try await WatchLaterEntry.query(on: db).filter(\.$user.$id == userID).all()
            let availability = AvailabilityService(db: db)
            let covered = try await availability.snapshots(titleIDs: entries.map(\.$title.id), region: region)
            for entry in entries where covered[entry.$title.id] == nil {
                guard let title = try await Title.find(entry.$title.id, on: db) else { continue }
                do {
                    try await availability.refresh(title, tmdb: tmdb)
                    try await AvailabilityNoticeService(db: db).reconcile(titleID: title.requireID())
                } catch let error as TMDBError {
                    logger.info("Verfügbarkeit für „\(title.name)“ nicht abgefragt: \(error)")
                    if error == .missingToken || error == .unauthorized { return }
                }
            }
        } catch {
            logger.warning("Verfügbarkeit nach Landwechsel: \(String(describing: type(of: error)))")
        }
    }
}

extension Request {
    var streamingSettings: StreamingSettingsService { StreamingSettingsService(db: db) }
}
