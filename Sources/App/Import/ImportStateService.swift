import Fluent
import Foundation
import Vapor

/// State of the Netflix import for one user (web „Import“ page and `GET /v1/imports/netflix`).
struct ImportStateService {
    let db: any Database
    let worker: MatchingWorker

    /// How many of the newest unmatched rows the page lists.
    static let unmatchedLimit = 50
    /// Accepted values of the mapping list filter.
    static let mappingFilters = ["all", "auto", "confirmed", "ignored"]

    /// The user's matching progress.
    ///
    /// Counted in the database: the import page polls this every 2 s (security audit F16).
    ///
    /// - Parameter userID: The user whose rows are counted.
    /// - Returns: Whether the worker runs, pending rows (without those waiting for review), rows waiting for review and the
    ///   user's last matching error.
    /// - Throws: A database error.
    func progress(userID: UUID) async throws -> ImportProgress {
        let pending = try await pendingRows(userID: userID).count()
        let waiting = try await pendingRows(userID: userID)
            .join(NetflixMapping.self, on: \NetflixRow.$mapping.$id == \NetflixMapping.$id)
            .filter(NetflixMapping.self, \.$status == MappingStatus.review.rawValue).count()
        return ImportProgress(isRunning: await worker.isRunning, pendingRows: pending - waiting,
                              waitingForReview: waiting, lastError: await worker.lastError(for: userID))
    }

    /// Query for the user's rows still waiting for matching.
    /// - Parameter userID: The owner of the rows.
    /// - Returns: A query builder filtered to the user's `pending` rows.
    private func pendingRows(userID: UUID) -> QueryBuilder<NetflixRow> {
        NetflixRow.query(on: db).filter(\.$user.$id == userID).filter(\.$status == RowStatus.pending.rawValue)
    }

    /// Query for the user's rows whose name is mapped but no episode fit.
    /// - Parameter userID: The owner of the rows.
    /// - Returns: A query builder filtered to the user's `unmatched` rows.
    private func unmatchedRows(userID: UUID) -> QueryBuilder<NetflixRow> {
        NetflixRow.query(on: db).filter(\.$user.$id == userID).filter(\.$status == RowStatus.unmatched.rawValue)
    }

    /// Everything the import page shows: progress, names to review with their pending rows, the newest unmatched rows
    /// and the filtered mapping list.
    ///
    /// `mappingFilter`: all (everything except review) | auto | confirmed | ignored; unknown → all.
    ///
    /// - Parameters:
    ///   - userID: The user whose import state is loaded.
    ///   - rawFilter: The requested mapping list filter.
    /// - Returns: The import state for the page or the API.
    /// - Throws: A database error.
    func state(userID: UUID, mappingFilter rawFilter: String) async throws -> ImportState {
        let filter = Self.mappingFilters.contains(rawFilter) ? rawFilter : "all"
        let mappings = try await NetflixMapping.query(on: db).filter(\.$user.$id == userID).with(\.$title)
            .sort(\.$netflixName).all()
        // Only rows that are shown: pending rows of names to review, and the newest unmatched rows (security audit F16).
        let reviewRows = try await pendingRows(userID: userID)
            .join(NetflixMapping.self, on: \NetflixRow.$mapping.$id == \NetflixMapping.$id)
            .filter(NetflixMapping.self, \.$status == MappingStatus.review.rawValue).all()
        let pendingByMapping = Dictionary(grouping: reviewRows, by: { $0.$mapping.id })

        let review = mappings.filter { $0.mappingStatus == .review }
            .map { ReviewItem(mapping: $0, rows: pendingByMapping[$0.id] ?? []) }
            .filter { $0.rowCount > 0 }
        let unmatchedTotal = try await unmatchedRows(userID: userID).count()
        let newestUnmatched = try await unmatchedRows(userID: userID).sort(\.$watchedOn, .descending).limit(Self.unmatchedLimit).all()
        let mappingByID = Dictionary(mappings.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let unmatched = newestUnmatched.map { row in
            let mapping = row.$mapping.id.flatMap { mappingByID[$0] }
            return UnmatchedItem(row: row, canAssign: mapping?.titleKind == .tv && mapping?.$title.id != nil)
        }
        let listed = mappings.filter { mapping in
            switch filter {
            case "auto", "confirmed", "ignored": mapping.status == filter
            default: mapping.mappingStatus != .review
            }
        }
        return ImportState(progress: try await progress(userID: userID), review: review, unmatched: unmatched,
                           unmatchedTotal: unmatchedTotal, mappings: listed.map { ($0, $0.title?.name) }, mappingFilter: filter)
    }
}

extension NetflixCSVError {
    /// German message shown by the web page and the API.
    var germanMessage: String {
        switch self {
        case .notNetflixHistory: ImportController.notNetflixMessage
        case let .invalidDate(line, value): "Zeile \(line): ungültiges Datum „\(value)“."
        case let .tooManyRows(limit):
            "Pro Konto werden höchstens \(limit.formatted(.number.locale(Locale(identifier: "de_DE")))) Netflix-Zeilen gespeichert – dieser Import würde die Grenze überschreiten."
        }
    }
}

extension Request {
    /// Import state service for this request, backed by the app's `MatchingWorker`.
    var importState: ImportStateService { ImportStateService(db: db, worker: application.matchingWorker) }
}
