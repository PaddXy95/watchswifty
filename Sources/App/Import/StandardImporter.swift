import Fluent
import Foundation
import Vapor

/// Matches standard import entries to TMDB titles and records their viewings, rating and comment
/// (spec `2026-11-19-standard-import-design.md` §3–§4).
struct StandardImporter {
    let db: any Database
    let tmdb: any TMDBClient
    let today: String
    /// The requesting user when they have no TMDB token: cached titles they do not use stay closed, as everywhere
    /// (security audit F14). nil for the worker, which always runs with the user's token.
    var tokenlessUser: UUID? = nil

    /// IDs first (with a plausibility check), then title and year; unclear entries go to review.
    func resolve(_ entry: ImportEntry) async throws {
        // A new upload may have replaced the list while the worker held this entry.
        guard let id = entry.id, try await ImportEntry.find(id, on: db) != nil else { return }
        let kind = entry.titleKind
        var idHit: TMDBSearchResult?
        if let hint = entry.tmdbHint {
            idHit = try await lookup(kind: kind, tmdbID: hint)
        }
        if idHit == nil, let imdbID = entry.imdbID {
            let found = try await tmdb.find(imdbID: imdbID)
            switch kind {
            case .movie:
                idHit = found.movies.first
            case .tv:
                if let series = found.series.first {
                    idHit = series
                } else if let showID = found.episodeShowIDs.first {
                    idHit = try await lookup(kind: .tv, tmdbID: showID)
                }
            }
        }
        if let idHit, plausibleIDMatch(title: entry.title, year: entry.year, found: idHit) {
            try await record(entry, tmdbID: idHit.id)
            return
        }
        let results = try await tmdb.search(entry.title, kind: kind)
        if let idHit {
            try await save(entry, status: .review, candidates: Array(([idHit] + results.filter { $0.id != idHit.id }).prefix(5)))
            return
        }
        switch chooseTitle(query: entry.title, year: entry.year, results: results) {
        case .match(let result):
            try await record(entry, tmdbID: result.id)
        case .review(let candidates):
            try await save(entry, status: .review, candidates: candidates)
        case .notFound:
            try await save(entry, status: .notFound, candidates: [])
        }
    }

    /// Search with the user's own words in the entry's kind: always shows the hits for picking.
    func search(_ entry: ImportEntry, query: String) async throws {
        let results = try await tmdb.search(query, kind: entry.titleKind)
        try await save(entry, status: results.isEmpty ? .notFound : .review, candidates: Array(results.prefix(8)))
    }

    /// Records the entry for the given title. Viewings already known (same movie/episode on the same day ±1, or any
    /// viewing of it for an undated row) are not added again; episodes the catalog lacks are counted as missing, after
    /// one refresh of a series that was cached before.
    func record(_ entry: ImportEntry, tmdbID: Int) async throws {
        let catalog = CatalogService(db: db, tmdb: tmdb, tokenlessUser: tokenlessUser)
        let kind = entry.titleKind
        let wasCached = try await cachedTitle(kind: kind, tmdbID: tmdbID) != nil
        let title = try await catalog.title(kind: kind, tmdbID: tmdbID)
        let titleID = try title.requireID()
        let userID = entry.$user.id
        let planned = entry.watchList

        var episodeIDs: [String: UUID] = [:]
        if kind == .tv {
            func key(_ season: Int, _ number: Int) -> String { "\(season)#\(number)" }
            func index() async throws -> [String: UUID] {
                var ids: [String: UUID] = [:]
                for episode in try await catalog.episodes(of: titleID) where ids[key(episode.season, episode.number)] == nil {
                    ids[key(episode.season, episode.number)] = try episode.requireID()
                }
                return ids
            }
            episodeIDs = try await index()
            let lacking = planned.contains { watch in
                guard let season = watch.season, let number = watch.episode else { return false }
                return episodeIDs[key(season, number)] == nil
            }
            if lacking && wasCached {
                try await catalog.refresh(title)
                episodeIDs = try await index()
            }
        }

        // All writes in one transaction, after checking that a new upload has not replaced the list meanwhile
        // (TMDB calls above can take seconds).
        let today = today
        let entryID = try entry.requireID()
        let episodeByKey = episodeIDs
        try await db.transaction { db in
            guard try await ImportEntry.find(entryID, on: db) != nil else { return }
            let userTitle = try await WatchService(db: db, today: { today }).userTitle(userID: userID, titleID: titleID)
            var existing = try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID).all()
            var added = 0
            var missing = 0
            for watch in planned {
                var episodeID: UUID?
                if kind == .tv {
                    guard let season = watch.season, let number = watch.episode, let id = episodeByKey["\(season)#\(number)"] else {
                        missing += 1
                        continue
                    }
                    episodeID = id
                }
                let day = watch.day.flatMap { CalendarDay.isValid($0) && $0 <= today ? $0 : nil }
                let known = existing.contains { other in
                    guard other.$episode.id == episodeID else { return false }
                    guard let day else { return true }
                    return other.watchedOn.map { abs(CalendarDay.daysBetween($0, day)) <= 1 } ?? false
                }
                if known { continue }
                let new = Watch(userID: userID, titleID: titleID, episodeID: episodeID, watchedOn: day, service: watch.service,
                                origin: .manual)
                try await new.save(on: db)
                existing.append(new)
                added += 1
            }

            if added > 0 { userTitle.hidden = false }
            if let rating = entry.rating { userTitle.rating = rating }
            if let comment = entry.comment {
                let current = userTitle.comment ?? ""
                if current.isEmpty {
                    userTitle.comment = comment
                } else if !current.contains(comment) {
                    let merged = current + "\n\n" + comment
                    if merged.count <= WatchService.maxCommentLength { userTitle.comment = merged }
                }
            }
            try await userTitle.save(on: db)

            entry.status = ImportEntryStatus.imported.rawValue
            entry.tmdbID = tmdbID
            entry.missingEpisodes = missing
            entry.addedWatches = added
            entry.setCandidates([])
            entry.error = nil
            try await entry.save(on: db)
        }
    }

    private func save(_ entry: ImportEntry, status: ImportEntryStatus, candidates: [TMDBSearchResult]) async throws {
        entry.status = status.rawValue
        entry.setCandidates(candidates)
        entry.error = nil
        try await entry.save(on: db)
    }

    private func cachedTitle(kind: TitleKind, tmdbID: Int) async throws -> Title? {
        try await Title.query(on: db).filter(\.$kind == kind.rawValue).filter(\.$tmdbID == tmdbID).first()
    }

    /// The title behind an ID from the file (cache first); nil when TMDB does not know it.
    private func lookup(kind: TitleKind, tmdbID: Int) async throws -> TMDBSearchResult? {
        if let cached = try await cachedTitle(kind: kind, tmdbID: tmdbID) {
            return TMDBSearchResult(id: tmdbID, kind: kind, name: cached.name, originalName: cached.originalName,
                                    year: cached.year, posterPath: cached.posterPath)
        }
        do {
            switch kind {
            case .movie:
                let movie = try await tmdb.movie(id: tmdbID)
                return TMDBSearchResult(id: movie.id, kind: .movie, name: movie.name, originalName: movie.originalName,
                                        year: movie.year, posterPath: movie.posterPath)
            case .tv:
                let series = try await tmdb.series(id: tmdbID)
                return TMDBSearchResult(id: series.id, kind: .tv, name: series.name, originalName: series.originalName,
                                        year: series.year, posterPath: series.posterPath)
            }
        } catch TMDBError.notFound {
            return nil
        }
    }
}

/// Resolves pending import entries in the background, one user after another with that user's token.
actor ImportWorker {
    private let db: any Database
    private let provider: TMDBProvider
    private let cipher: TokenCipher
    private let logger: Logger
    private let today: @Sendable () -> String
    private let enabled: Bool
    private var running = false
    private var rerun = false

    init(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger,
         today: @escaping @Sendable () -> String, enabled: Bool) {
        self.db = db
        self.provider = provider
        self.cipher = cipher
        self.logger = logger
        self.today = today
        self.enabled = enabled
    }

    func kick() {
        guard enabled else { return }
        Task { _ = try? await self.processAll() }
    }

    /// One pass over all pending entries; returns how many were resolved. A call during a pass schedules another pass.
    func processAll() async throws -> Int {
        if running {
            rerun = true
            return 0
        }
        running = true
        defer { running = false }
        var resolved = 0
        repeat {
            rerun = false
            let pending = try await ImportEntry.query(on: db).filter(\.$status == ImportEntryStatus.pending.rawValue)
                .sort(\.$position).all()
            for (userID, entries) in Dictionary(grouping: pending, by: { $0.$user.id }) {
                guard let token = cipher.open(try await User.find(userID, on: db)?.tmdbToken) else {
                    for entry in entries {
                        entry.error = TMDBError.missingToken.description
                        try await entry.save(on: db)
                    }
                    continue
                }
                let importer = StandardImporter(db: db, tmdb: provider.make(token), today: today())
                for entry in entries.sorted(by: { $0.position < $1.position }) {
                    do {
                        try await importer.resolve(entry)
                        resolved += 1
                    } catch let error as TMDBError {
                        entry.error = error.description
                        try await entry.save(on: db)
                        // Token, rate limit or TMDB down: the rest would fail too. Anything else concerns this entry
                        // only, which must not keep the user's other entries waiting.
                        guard Self.stopsPass(error) else { continue }
                        logger.warning("Standard-Import: TMDB-Fehler, Rest folgt beim nächsten Versuch: \(error)")
                        break
                    } catch {
                        entry.error = "Fehler: \(error)"
                        try await entry.save(on: db)
                    }
                }
            }
        } while rerun
        if resolved > 0 { logger.info("Standard-Import: \(resolved) Titel zugeordnet") }
        return resolved
    }
}

extension ImportWorker {
    static func stopsPass(_ error: TMDBError) -> Bool {
        switch error {
        case .missingToken, .unauthorized, .rateLimited, .network: true
        case .http(let code): code >= 500
        case .notFound, .invalidResponse: false
        }
    }
}

extension Application {
    private struct ImportWorkerKey: StorageKey { typealias Value = ImportWorker }

    var importWorker: ImportWorker {
        get {
            guard let worker = storage[ImportWorkerKey.self] else { fatalError("Import worker not configured") }
            return worker
        }
        set { storage[ImportWorkerKey.self] = newValue }
    }
}

/// Resumes entries left pending by a restart.
struct ImportWorkerLifecycle: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        await application.importWorker.kick()
    }
}
