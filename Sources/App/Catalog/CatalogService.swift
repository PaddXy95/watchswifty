import Fluent
import Foundation
import Vapor

/// Reads and refreshes the shared TMDB cache (`titles`, `episodes`).
struct CatalogService {
    let db: any Database
    let tmdb: any TMDBClient

    static let maxAge: TimeInterval = 7 * 86_400

    /// Cached title, or fetched from TMDB (a new series also loads all episodes).
    func title(kind: TitleKind, tmdbID: Int) async throws -> Title {
        if let cached = try await Title.query(on: db)
            .filter(\.$kind == kind.rawValue).filter(\.$tmdbID == tmdbID).first() {
            return cached
        }
        let title = Title(tmdbID: tmdbID, kind: kind, name: "")
        try await refresh(title)
        return title
    }

    func refresh(_ title: Title, now: Date = .now) async throws {
        switch title.titleKind {
        case .movie:
            let movie = try await tmdb.movie(id: title.tmdbID)
            title.name = movie.name
            title.originalName = movie.originalName
            title.year = movie.year
            title.posterPath = movie.posterPath
            title.refreshedAt = now
            try await title.save(on: db)
        case .tv:
            let series = try await tmdb.series(id: title.tmdbID)
            var seasons: [[TMDBEpisode]] = []
            for number in series.seasonNumbers {
                seasons.append(try await tmdb.season(seriesID: series.id, number: number))
            }
            title.name = series.name
            title.originalName = series.originalName
            title.year = series.year
            title.posterPath = series.posterPath
            title.tmdbStatus = series.status
            title.refreshedAt = now
            let episodes = seasons.flatMap { $0 }
            try await db.transaction { db in
                try await title.save(on: db)
                try await upsertEpisodes(episodes, titleID: title.requireID(), on: db)
            }
        }
    }

    func refreshIfStale(_ title: Title, now: Date = .now, maxAge: TimeInterval = CatalogService.maxAge) async throws {
        if let refreshed = title.refreshedAt, now.timeIntervalSince(refreshed) < maxAge { return }
        try await refresh(title, now: now)
    }

    func episodes(of titleID: UUID) async throws -> [Episode] {
        try await Episode.query(on: db).filter(\.$title.$id == titleID)
            .sort(\.$season).sort(\.$number).all()
    }

    private func upsertEpisodes(_ fetched: [TMDBEpisode], titleID: UUID, on db: any Database) async throws {
        let existing = try await Episode.query(on: db).filter(\.$title.$id == titleID).all()
        var byKey = Dictionary(existing.map { ("\($0.season)/\($0.number)", $0) }, uniquingKeysWith: { first, _ in first })
        for item in fetched {
            let key = "\(item.season)/\(item.number)"
            if let episode = byKey[key] {
                guard episode.name != item.name || episode.airDate != item.airDate || episode.tmdbEpisodeID != item.id else { continue }
                episode.name = item.name
                episode.airDate = item.airDate
                episode.tmdbEpisodeID = item.id
                try await episode.save(on: db)
            } else {
                let episode = Episode(titleID: titleID, season: item.season, number: item.number, name: item.name,
                                      airDate: item.airDate, tmdbEpisodeID: item.id)
                try await episode.save(on: db)
                byKey[key] = episode
            }
        }
    }
}

extension Request {
    var catalog: CatalogService { CatalogService(db: db, tmdb: tmdb) }
}
