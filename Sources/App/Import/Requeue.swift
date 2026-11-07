import Fluent
import Foundation

/// After a title's TMDB data changed, its „nicht zugeordnet“ rows get another chance.
/// Returns how many rows went back to pending.
@discardableResult
func requeueUnmatchedRows(titleID: UUID, on db: any Database) async throws -> Int {
    let mappings = try await NetflixMapping.query(on: db).filter(\.$title.$id == titleID).all().compactMap(\.id)
    guard !mappings.isEmpty else { return 0 }
    let rows = try await NetflixRow.query(on: db).filter(\.$mapping.$id ~~ mappings)
        .filter(\.$status == RowStatus.unmatched.rawValue).all()
    guard !rows.isEmpty else { return 0 }
    try await NetflixRow.query(on: db).filter(\.$id ~~ rows.compactMap(\.id))
        .set(\.$status, to: RowStatus.pending.rawValue).update()
    return rows.count
}
