import Fluent
import Foundation
import Vapor

/// Matches film list entries to TMDB movies and records their viewings, rating and comment.
struct FilmListImporter {
    let db: any Database
    let tmdb: any TMDBClient
    let today: String

    /// Automatic match by title and year; unclear entries go to review.
    func resolve(_ entry: FilmListEntry) async throws {
        let results = try await tmdb.search(entry.title, kind: .movie)
        switch chooseFilm(query: entry.title, year: entry.year, results: results) {
        case .match(let result):
            try await record(entry, tmdbID: result.id)
        case .review(let candidates):
            entry.status = FilmListStatus.review.rawValue
            entry.setCandidates(candidates)
            entry.error = nil
            try await entry.save(on: db)
        case .notFound:
            entry.status = FilmListStatus.notFound.rawValue
            entry.setCandidates([])
            entry.error = nil
            try await entry.save(on: db)
        }
    }

    /// Search with the user's own words: always shows the hits for picking.
    func search(_ entry: FilmListEntry, query: String) async throws {
        let results = try await tmdb.search(query, kind: .movie)
        entry.status = (results.isEmpty ? FilmListStatus.notFound : .review).rawValue
        entry.setCandidates(Array(results.prefix(8)))
        entry.error = nil
        try await entry.save(on: db)
    }

    /// Records the entry for the given movie. Viewings already known (same day ±1, or any viewing for an undated row)
    /// are not added again; the comment is appended to an existing one unless it is already in there.
    func record(_ entry: FilmListEntry, tmdbID: Int) async throws {
        let title = try await CatalogService(db: db, tmdb: tmdb).title(kind: .movie, tmdbID: tmdbID)
        let titleID = try title.requireID()
        let userID = entry.$user.id
        let watchService = WatchService(db: db, today: { [today] in today })
        let userTitle = try await watchService.userTitle(userID: userID, titleID: titleID)

        var existing = try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$title.$id == titleID)
            .filter(\.$episode.$id == nil).all()
        for watch in entry.watchList {
            let day = watch.day.flatMap { CalendarDay.isValid($0) && $0 <= today ? $0 : nil }
            let known = existing.contains { other in
                guard let day else { return true }
                return other.watchedOn.map { abs(CalendarDay.daysBetween($0, day)) <= 1 } ?? false
            }
            if known { continue }
            let new = Watch(userID: userID, titleID: titleID, episodeID: nil, watchedOn: day, service: watch.service, origin: .manual)
            try await new.save(on: db)
            existing.append(new)
        }

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

        entry.status = FilmListStatus.imported.rawValue
        entry.tmdbID = tmdbID
        entry.setCandidates([])
        entry.error = nil
        try await entry.save(on: db)
    }
}

/// Resolves pending film list entries in the background, one user after another with that user's token.
actor FilmListWorker {
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
            let pending = try await FilmListEntry.query(on: db).filter(\.$status == FilmListStatus.pending.rawValue)
                .sort(\.$position).all()
            for (userID, entries) in Dictionary(grouping: pending, by: { $0.$user.id }) {
                guard let token = cipher.open(try await User.find(userID, on: db)?.tmdbToken) else {
                    for entry in entries {
                        entry.error = TMDBError.missingToken.description
                        try await entry.save(on: db)
                    }
                    continue
                }
                let importer = FilmListImporter(db: db, tmdb: provider.make(token), today: today())
                for entry in entries.sorted(by: { $0.position < $1.position }) {
                    do {
                        try await importer.resolve(entry)
                        resolved += 1
                    } catch let error as TMDBError {
                        entry.error = error.description
                        try await entry.save(on: db)
                        logger.warning("Filmliste: TMDB-Fehler, Rest folgt beim nächsten Versuch: \(error)")
                        break
                    } catch {
                        entry.error = "Fehler: \(error)"
                        try await entry.save(on: db)
                    }
                }
            }
        } while rerun
        if resolved > 0 { logger.info("Filmliste: \(resolved) Filme zugeordnet") }
        return resolved
    }
}

extension Application {
    private struct FilmListWorkerKey: StorageKey { typealias Value = FilmListWorker }

    var filmListWorker: FilmListWorker {
        get {
            guard let worker = storage[FilmListWorkerKey.self] else { fatalError("Film list worker not configured") }
            return worker
        }
        set { storage[FilmListWorkerKey.self] = newValue }
    }
}
