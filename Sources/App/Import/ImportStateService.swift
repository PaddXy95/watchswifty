import Fluent
import Foundation
import Vapor

/// State of the Netflix import for one user (web „Import“ page and `GET /v1/imports/netflix`).
struct ImportStateService {
    let db: any Database
    let worker: MatchingWorker

    static let unmatchedLimit = 50
    static let mappingFilters = ["all", "auto", "confirmed", "ignored"]

    /// Counted in the database: the import page polls this every 2 s (security audit F16).
    func progress(userID: UUID) async throws -> ImportProgress {
        let pending = try await pendingRows(userID: userID).count()
        let waiting = try await pendingRows(userID: userID)
            .join(NetflixMapping.self, on: \NetflixRow.$mapping.$id == \NetflixMapping.$id)
            .filter(NetflixMapping.self, \.$status == MappingStatus.review.rawValue).count()
        return ImportProgress(isRunning: await worker.isRunning, pendingRows: pending - waiting,
                              waitingForReview: waiting, lastError: await worker.lastError(for: userID))
    }

    private func pendingRows(userID: UUID) -> QueryBuilder<NetflixRow> {
        NetflixRow.query(on: db).filter(\.$user.$id == userID).filter(\.$status == RowStatus.pending.rawValue)
    }

    private func unmatchedRows(userID: UUID) -> QueryBuilder<NetflixRow> {
        NetflixRow.query(on: db).filter(\.$user.$id == userID).filter(\.$status == RowStatus.unmatched.rawValue)
    }

    /// `mappingFilter`: all (everything except review) | auto | confirmed | ignored; unknown → all.
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
    var importState: ImportStateService { ImportStateService(db: db, worker: application.matchingWorker) }
}
