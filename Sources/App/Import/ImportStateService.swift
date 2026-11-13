import Fluent
import Foundation
import Vapor

/// State of the Netflix import for one user (web „Import“ page and `GET /v1/imports/netflix`).
struct ImportStateService {
    let db: any Database
    let worker: MatchingWorker

    static let unmatchedLimit = 50
    static let mappingFilters = ["all", "auto", "confirmed", "ignored"]

    func progress(userID: UUID) async throws -> ImportProgress {
        let review = try await NetflixMapping.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$status == MappingStatus.review.rawValue).all().compactMap(\.id)
        let pending = try await NetflixRow.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$status == RowStatus.pending.rawValue).all()
        let waiting = pending.filter { $0.$mapping.id.map(review.contains) ?? false }.count
        return ImportProgress(isRunning: await worker.isRunning, pendingRows: pending.count - waiting,
                              waitingForReview: waiting, lastError: await worker.lastError(for: userID))
    }

    /// `mappingFilter`: all (everything except review) | auto | confirmed | ignored; unknown → all.
    func state(userID: UUID, mappingFilter rawFilter: String) async throws -> ImportState {
        let filter = Self.mappingFilters.contains(rawFilter) ? rawFilter : "all"
        let mappings = try await NetflixMapping.query(on: db).filter(\.$user.$id == userID).with(\.$title)
            .sort(\.$netflixName).all()
        let rows = try await NetflixRow.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue]).all()
        let pendingByMapping = Dictionary(grouping: rows.filter { $0.rowStatus == .pending }, by: { $0.$mapping.id })

        let review = mappings.filter { $0.mappingStatus == .review }
            .map { ReviewItem(mapping: $0, rows: pendingByMapping[$0.id] ?? []) }
            .filter { $0.rowCount > 0 }
        let unmatchedRows = rows.filter { $0.rowStatus == .unmatched }.sorted { $0.watchedOn > $1.watchedOn }
        let mappingByID = Dictionary(mappings.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let unmatched = unmatchedRows.prefix(Self.unmatchedLimit).map { row in
            let mapping = row.$mapping.id.flatMap { mappingByID[$0] }
            return UnmatchedItem(row: row, canAssign: mapping?.titleKind == .tv && mapping?.$title.id != nil)
        }
        let listed = mappings.filter { mapping in
            switch filter {
            case "auto", "confirmed", "ignored": mapping.status == filter
            default: mapping.mappingStatus != .review
            }
        }
        return ImportState(progress: try await progress(userID: userID), review: review, unmatched: Array(unmatched),
                           unmatchedTotal: unmatchedRows.count, mappings: listed.map { ($0, $0.title?.name) }, mappingFilter: filter)
    }
}

extension NetflixCSVError {
    /// German message shown by the web page and the API.
    var germanMessage: String {
        switch self {
        case .notNetflixHistory: ImportController.notNetflixMessage
        case let .invalidDate(line, value): "Zeile \(line): ungültiges Datum „\(value)“."
        }
    }
}

extension Request {
    var importState: ImportStateService { ImportStateService(db: db, worker: application.matchingWorker) }
}
