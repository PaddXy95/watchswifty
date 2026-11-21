import Fluent
import Foundation
import Vapor

/// A user's country and streaming services (Konto → Streamingdienste).
struct StreamingSettings: Sendable, Equatable {
    /// The user's country code (`DE` when none is set).
    let region: String
    /// TMDB provider ids of the user's services.
    let providerIDs: Set<Int>
}

/// Konto → Streamingdienste and `/v1/me/streaming-services` (spec §2).
struct StreamingSettingsService {
    /// Validation message for an invalid country code.
    static let regionMessage = "Unbekanntes Land."
    /// Validation message for an invalid service selection.
    static let providersMessage = "Ungültige Auswahl der Streamingdienste."
    /// Maximum number of services a user can select.
    static let maxProviders = 200

    /// The database holding the settings.
    let db: any Database

    /// The user's current country and services.
    /// - Parameter user: The user.
    /// - Returns: The stored settings.
    /// - Throws: Fluent's error for a user without ID, or database errors.
    func settings(user: User) async throws -> StreamingSettings {
        StreamingSettings(region: user.region,
                          providerIDs: try await AvailabilityNoticeService(db: db).serviceIDs(userID: user.requireID()))
    }

    /// Replaces country and services. Any change re-baselines the user's list, so titles already running at a new service
    /// or in the new country are not reported. Returns whether the country changed.
    /// - Parameters:
    ///   - user: The user.
    ///   - region: The new country code (two uppercase letters).
    ///   - providerIDs: The new services (TMDB provider ids; duplicates are ignored).
    /// - Returns: `true` if the country changed; `false` also when nothing changed at all.
    /// - Throws: `APIError.validation` with ``regionMessage`` or ``providersMessage`` for invalid input, or database errors.
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
    ///
    /// Errors are logged, never thrown; a missing or invalid TMDB token stops the remaining fetches.
    /// - Parameters:
    ///   - userID: The user.
    ///   - region: The new country code.
    ///   - tmdb: The user's TMDB client.
    ///   - logger: Receives info and warnings.
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
                } catch {
                    logger.warning("Verfügbarkeit für „\(title.name)“ nicht abgefragt: \(String(describing: type(of: error)))")
                }
            }
        } catch {
            logger.warning("Verfügbarkeit nach Landwechsel: \(String(describing: type(of: error)))")
        }
    }
}

extension Request {
    /// The streaming settings service for this request.
    var streamingSettings: StreamingSettingsService { StreamingSettingsService(db: db) }
}
