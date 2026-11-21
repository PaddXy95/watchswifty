import Fluent
import Foundation
import Vapor

/// Reads and refreshes the shared TMDB cache (`titles`, `episodes`).
struct CatalogService {
    /// The database holding the cache.
    let db: any Database
    /// The TMDB client used for fetches (normally with the requesting user's token).
    let tmdb: any TMDBClient

    /// Set for a request of a user without a TMDB token: a cached title is only served when this user uses it, so the
    /// answer is the same as for an uncached title and does not reveal what other users track (security audit F14).
    var tokenlessUser: UUID?

    /// Default maximum age for ``refreshIfStale(_:now:maxAge:)`` (7 days).
    static let maxAge: TimeInterval = 7 * 86_400

    /// Cached title, or fetched from TMDB (a new series also loads all episodes).
    /// - Parameters:
    ///   - kind: Series or movie.
    ///   - tmdbID: The title's TMDB id.
    /// - Returns: The cached title, or a newly fetched and saved one.
    /// - Throws: `TMDBError.missingToken` when ``tokenlessUser`` is set and does not use the cached title; otherwise the
    ///   errors of ``refresh(_:now:)``.
    func title(kind: TitleKind, tmdbID: Int) async throws -> Title {
        if let cached = try await Title.query(on: db)
            .filter(\.$kind == kind.rawValue).filter(\.$tmdbID == tmdbID).first() {
            if let tokenlessUser, try await !usesTitle(userID: tokenlessUser, title: cached, on: db) {
                throw TMDBError.missingToken
            }
            return cached
        }
        let title = Title(tmdbID: tmdbID, kind: kind, name: "")
        try await refresh(title)
        return title
    }

    /// Fetches the title from TMDB and overwrites the cached data, setting `refreshedAt` to `now`.
    ///
    /// A movie updates only its `titles` row. A series also loads every season and upserts its episodes in one
    /// transaction; episodes TMDB no longer returns are kept (watches point to them), they just stop being "current".
    /// Missing optional fields are stored as `""`/`0` so "TMDB has none" differs from "not fetched yet" (nil).
    /// - Parameters:
    ///   - title: The title to refresh; a new, unsaved title is inserted.
    ///   - now: The refresh time stored on the title and on returned episodes.
    /// - Throws: `TMDBError` from the client (a missing IMDb id for a series is tolerated), or database errors.
    func refresh(_ title: Title, now: Date = .now) async throws {
        switch title.titleKind {
        case .movie:
            let movie = try await tmdb.movie(id: title.tmdbID)
            title.name = movie.name
            title.originalName = movie.originalName
            title.year = movie.year
            title.posterPath = movie.posterPath
            title.overview = movie.overview ?? ""
            title.imdbID = movie.imdbID ?? ""
            title.runtime = movie.runtime ?? 0
            title.genreList = Genre.from(tmdbIDs: movie.genreIDs)
            title.refreshedAt = now
            try await title.save(on: db)
        case .tv:
            let series = try await tmdb.series(id: title.tmdbID)
            let imdbID: String?
            do { imdbID = try await tmdb.seriesIMDbID(id: series.id) } catch TMDBError.notFound { imdbID = nil }
            var seasons: [[TMDBEpisode]] = []
            for number in series.seasonNumbers {
                seasons.append(try await tmdb.season(seriesID: series.id, number: number))
            }
            title.name = series.name
            title.originalName = series.originalName
            title.year = series.year
            title.posterPath = series.posterPath
            title.tmdbStatus = series.status
            title.overview = series.overview ?? ""
            title.imdbID = imdbID ?? ""
            title.runtime = series.episodeRunTime ?? 0
            title.genreList = Genre.from(tmdbIDs: series.genreIDs)
            title.refreshedAt = now
            let episodes = seasons.flatMap { $0 }
            try await db.transaction { db in
                try await title.save(on: db)
                try await upsertEpisodes(episodes, titleID: title.requireID(), now: now, on: db)
            }
        }
    }

    /// Refreshes the title only when it was never refreshed or its last refresh is at least `maxAge` old.
    /// - Parameters:
    ///   - title: The cached title.
    ///   - now: The reference time.
    ///   - maxAge: The age from which the title counts as stale.
    /// - Throws: The errors of ``refresh(_:now:)``.
    func refreshIfStale(_ title: Title, now: Date = .now, maxAge: TimeInterval = CatalogService.maxAge) async throws {
        if let refreshed = title.refreshedAt, now.timeIntervalSince(refreshed) < maxAge { return }
        try await refresh(title, now: now)
    }

    /// Cached episodes of a title, sorted by season and episode number.
    /// - Parameter titleID: The title's ID.
    /// - Returns: All cached episodes, including ones TMDB no longer returns.
    /// - Throws: Database errors.
    func episodes(of titleID: UUID) async throws -> [Episode] {
        try await Episode.query(on: db).filter(\.$title.$id == titleID)
            .sort(\.$season).sort(\.$number).all()
    }

    /// Inserts or updates the fetched episodes; new rows get `firstSeenAt`, every returned row `lastSeenAt` = `now`.
    ///
    /// Unchanged rows only get the new `lastSeenAt`; rows missing from `fetched` are left untouched.
    /// - Parameters:
    ///   - fetched: The episodes TMDB returned for the series.
    ///   - titleID: The series' ID.
    ///   - now: The refresh time.
    ///   - db: The database (the caller's transaction).
    /// - Throws: Database errors.
    private func upsertEpisodes(_ fetched: [TMDBEpisode], titleID: UUID, now: Date, on db: any Database) async throws {
        let existing = try await Episode.query(on: db).filter(\.$title.$id == titleID).all()
        var byKey = Dictionary(existing.map { ("\($0.season)/\($0.number)", $0) }, uniquingKeysWith: { first, _ in first })
        for item in fetched {
            let key = "\(item.season)/\(item.number)"
            let overview = item.overview ?? ""
            let runtime = item.runtime ?? 0
            if let episode = byKey[key] {
                guard episode.name != item.name || episode.airDate != item.airDate || episode.tmdbEpisodeID != item.id
                    || episode.overview != overview || episode.runtime != runtime else { continue }
                episode.name = item.name
                episode.airDate = item.airDate
                episode.tmdbEpisodeID = item.id
                episode.overview = overview
                episode.runtime = runtime
                try await episode.save(on: db)
            } else {
                let episode = Episode(titleID: titleID, season: item.season, number: item.number, name: item.name,
                                      airDate: item.airDate, tmdbEpisodeID: item.id)
                episode.overview = overview
                episode.runtime = runtime
                episode.firstSeenAt = now
                episode.lastSeenAt = now
                try await episode.save(on: db)
                byKey[key] = episode
            }
        }
        let returned = Set(fetched.map { "\($0.season)/\($0.number)" }).compactMap { byKey[$0]?.id }
        if !returned.isEmpty {
            try await Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$id ~~ returned)
                .set(\.$lastSeenAt, to: now).update()
        }
    }
}

extension Request {
    /// The catalog service for this request, using the logged-in user's TMDB token; for a user without a token it is
    /// restricted to cached titles that user uses (``CatalogService/tokenlessUser``).
    var catalog: CatalogService {
        CatalogService(db: db, tmdb: tmdb, tokenlessUser: tmdbToken == nil ? auth.get(User.self)?.id : nil)
    }
}
