import Fluent
import Foundation
import Vapor

/// A TMDB search hit with the user's own progress (web search page and `GET /v1/search`).
struct SearchHit {
    let result: TMDBSearchResult
    let inLibrary: Bool
    /// Series only: watched / total regular episodes (nil unless the series is in the user's library: which series
    /// are cached reflects other users' tracking, security audit F14).
    let watchedEpisodes: Int?
    let totalEpisodes: Int?
    let movieWatched: Bool
    let rating: Int?
    /// On the user's „Später ansehen“ list.
    var watchLater = false

    /// Web badge: „3/10 gesehen“, „gesehen“.
    var status: String? {
        if result.kind == .tv, let watched = watchedEpisodes, watched > 0, let total = totalEpisodes { return "\(watched)/\(total) gesehen" }
        return movieWatched ? "gesehen" : nil
    }
}

/// Runs TMDB searches and adds the user's own progress to the hits.
struct SearchService {
    let db: any Database
    let tmdb: any TMDBClient

    /// TMDB multi search (at least 2 characters after trimming, otherwise no results).
    /// - Parameters:
    ///   - userID: The user whose progress, ratings and „Später ansehen“ (watch later) list are added.
    ///   - rawQuery: The query as typed.
    /// - Returns: One hit per TMDB result, in TMDB's order.
    /// - Throws: TMDB errors (e.g. no token) and database errors.
    func search(userID: UUID, query rawQuery: String) async throws -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let results = try await tmdb.searchMulti(query)
        guard !results.isEmpty else { return [] }

        let cached = try await Title.query(on: db).filter(\.$tmdbID ~~ results.map(\.id)).all()
            .filter { title in results.contains { $0.id == title.tmdbID && $0.kind == title.titleKind } }
        let titleIDs = try cached.map { try $0.requireID() }
        let watches = titleIDs.isEmpty ? [] : try await Watch.query(on: db)
            .filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let entries = titleIDs.isEmpty ? [] : try await UserTitle.query(on: db)
            .filter(\.$user.$id == userID).filter(\.$title.$id ~~ titleIDs).all()
        let episodes = titleIDs.isEmpty ? [] : try await Episode.query(on: db)
            .filter(\.$title.$id ~~ titleIDs).filter(\.$season >= 1).all()

        let laterTV = try await WatchLaterService(db: db).containsTMDB(userID: userID, kind: .tv,
                                                                       tmdbIDs: results.filter { $0.kind == .tv }.map(\.id))
        let laterMovies = try await WatchLaterService(db: db).containsTMDB(userID: userID, kind: .movie,
                                                                           tmdbIDs: results.filter { $0.kind == .movie }.map(\.id))
        return results.map { result in
            var hit = hit(for: result)
            hit.watchLater = (result.kind == .tv ? laterTV : laterMovies).contains(result.id)
            return hit
        }

        /// Builds the hit for one TMDB result from the cached title, the user's watches and library entry.
        /// - Parameter result: The TMDB result.
        /// - Returns: The hit; without a cached title it carries no progress.
        func hit(for result: TMDBSearchResult) -> SearchHit {
            guard let title = cached.first(where: { $0.tmdbID == result.id && $0.titleKind == result.kind }), let id = title.id else {
                return SearchHit(result: result, inLibrary: false, watchedEpisodes: nil, totalEpisodes: nil, movieWatched: false, rating: nil)
            }
            let own = watches.filter { $0.$title.id == id }
            let entry = entries.first { $0.$title.id == id }
            let regular = Set(episodes.filter { $0.$title.id == id }.compactMap(\.id))
            let seen = Set(own.compactMap(\.$episode.id)).intersection(regular)
            let inLibrary = !own.isEmpty || entry != nil
            return SearchHit(result: result, inLibrary: inLibrary,
                             watchedEpisodes: result.kind == .tv && inLibrary ? seen.count : nil,
                             totalEpisodes: result.kind == .tv && inLibrary ? regular.count : nil,
                             movieWatched: result.kind == .movie && !own.isEmpty, rating: entry?.rating)
        }
    }
}
