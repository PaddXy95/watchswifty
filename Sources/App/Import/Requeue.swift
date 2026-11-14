import Fluent
import Foundation

/// After a title's TMDB data changed, its „nicht zugeordnet“ rows get another chance.
/// Returns how many rows went back to pending.
@discardableResult
func requeueUnmatchedRows(titleID: UUID, on db: any Database) async throws -> Int {
    let rows = try await NetflixRow.query(on: db).filter(\.$status == RowStatus.unmatched.rawValue)
        .join(NetflixMapping.self, on: \NetflixRow.$mapping.$id == \NetflixMapping.$id)
        .filter(NetflixMapping.self, \.$title.$id == titleID)
        .all(\.$id).compactMap { $0 }
    for chunk in rows.chunked() {
        try await NetflixRow.query(on: db).filter(\.$id ~~ chunk).set(\.$status, to: RowStatus.pending.rawValue).update()
    }
    return rows.count
}
