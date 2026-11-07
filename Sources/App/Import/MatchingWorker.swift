import Fluent
import Foundation
import Vapor

struct MatchingRunResult: Sendable, Equatable {
    var matched = 0
    var unmatched = 0
    var awaitingReview = 0
}

/// Background matching of pending Netflix rows to TMDB titles/episodes (§6.2 steps 2–5).
/// One run at a time across all users; TMDB failures stop the run and leave rows pending.
actor MatchingWorker {
    private let db: any Database
    private let provider: TMDBProvider
    private let logger: Logger
    private let enabled: Bool
    /// Shared with MappingService so user decisions and worker writes never interleave.
    private let lock: AsyncMutex
    private let retryDelay: Duration
    private var retryScheduled = false

    private(set) var isRunning = false
    private var processing = false
    /// Last problem per user (missing/rejected token, TMDB down); cleared after a clean run for that user.
    private var errors: [UUID: String] = [:]
    private var failedThisRun: Set<UUID> = []
    private var rerunRequested = false

    init(db: any Database, provider: TMDBProvider, logger: Logger, enabled: Bool, lock: AsyncMutex = AsyncMutex(),
         retryDelay: Duration = .seconds(300)) {
        self.db = db
        self.provider = provider
        self.logger = logger
        self.enabled = enabled
        self.lock = lock
        self.retryDelay = retryDelay
    }

    func lastError(for userID: UUID) -> String? { errors[userID] }

    /// Runs `body` (actor-isolated) while holding the shared import lock.
    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        await lock.lock()
        do {
            let result = try await body()
            await lock.unlock()
            return result
        } catch {
            await lock.unlock()
            throw error
        }
    }

    /// Starts a run in the background (no-op when disabled); a kick during a run schedules another pass.
    func kick() {
        guard enabled else { return }
        if isRunning {
            rerunRequested = true
            return
        }
        isRunning = true
        Task { await self.runLoop() }
    }

    private func runLoop() async {
        repeat {
            rerunRequested = false
            do {
                let result = try await processAll()
                logger.info("Zuordnung: \(result.matched) zugeordnet, \(result.unmatched) nicht zugeordnet, \(result.awaitingReview) zu prüfen")
            } catch {
                logger.error("Matching failed: \(error)")
                await recordForPendingUsers("Zuordnung fehlgeschlagen: \(error)")
            }
        } while rerunRequested
        isRunning = false
        if !failedThisRun.isEmpty { scheduleRetry() }
    }

    /// After a run with per-user failures (TMDB down, token rejected …) try again later by itself.
    private func scheduleRetry() {
        guard enabled, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        Task {
            try? await Task.sleep(for: delay)
            await self.retryNow()
        }
    }

    private func retryNow() {
        retryScheduled = false
        kick()
    }

    private func recordForPendingUsers(_ message: String) async {
        guard let users = try? await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue).all().map(\.$user.id) else { return }
        for user in Set(users) {
            failedThisRun.insert(user)
            errors[user] = message
        }
    }

    private var watches: WatchService { WatchService(db: db) }

    /// One pass over all pending work. A call while another pass is in progress returns at once.
    func processAll() async throws -> MatchingRunResult {
        guard !processing else { return MatchingRunResult() }
        processing = true
        defer { processing = false }
        var result = MatchingRunResult()
        failedThisRun = []
        var touchedUsers: Set<UUID> = []
        var changed = true
        while changed {
            changed = false
            if try await assignMappings() { changed = true }
            let resolved = try await resolveMappings()
            touchedUsers.formUnion(resolved.users)
            if resolved.changed { changed = true }
            try await ignoreRowsOfIgnoredMappings()
            let (matched, unmatched) = try await matchRows()
            result.matched += matched
            result.unmatched += unmatched
            if matched + unmatched > 0 { changed = true }
        }
        for user in touchedUsers.subtracting(failedThisRun) { errors[user] = nil }
        result.awaitingReview = try await awaitingReviewCount()
        return result
    }

    // MARK: Step 1 – mapping keys

    /// Gives every pending row without a mapping its (name, kind) mapping.
    private func assignMappings() async throws -> Bool {
        try await locked { try await assignMappingsLocked() }
    }

    private func assignMappingsLocked() async throws -> Bool {
        let rows = try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue).filter(\.$mapping.$id == nil).all()
        guard !rows.isEmpty else { return false }
        for (userID, userRows) in Dictionary(grouping: rows, by: { $0.$user.id }) {
            let seasonless = Set(userRows.compactMap { $0.parsedKind == "episode" && $0.seasonNumber == nil ? $0.showName : nil })
            var showCounts: [String: Int] = [:]
            if !seasonless.isEmpty {
                for row in try await NetflixRow.query(on: db).filter(\.$user.$id == userID).filter(\.$showName ~~ Array(seasonless)).all() {
                    if let show = row.showName { showCounts[show, default: 0] += 1 }
                }
            }
            for row in userRows {
                let key: (String, TitleKind)
                if row.parsedKind == "movie" {
                    key = (row.rawTitle, .movie)
                } else if row.seasonNumber == nil, let show = row.showName, showCounts[show] == 1 {
                    key = (row.rawTitle, .movie)   // single row "X: Y" might be a movie with a colon
                } else {
                    key = (row.showName ?? row.rawTitle, .tv)
                }
                let mapping = try await mapping(userID: userID, name: key.0, kind: key.1)
                row.$mapping.id = try mapping.requireID()
                try await row.save(on: db)
            }
        }
        return true
    }

    private func mapping(userID: UUID, name: String, kind: TitleKind) async throws -> NetflixMapping {
        if let existing = try await NetflixMapping.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$netflixName == name).filter(\.$kind == kind.rawValue).first() {
            return existing
        }
        let created = NetflixMapping(userID: userID, netflixName: name, kind: kind)
        try await created.save(on: db)
        return created
    }

    // MARK: Step 2 – resolve names via TMDB

    /// Resolves pending mappings with each owner's own token. A user without (or with a rejected)
    /// token is skipped for the rest of the run; other users continue.
    private func resolveMappings() async throws -> (changed: Bool, users: Set<UUID>) {
        let pending = try await NetflixMapping.query(on: db).filter(\.$status == MappingStatus.pending.rawValue).all()
        var changed = false
        let byUser = Dictionary(grouping: pending, by: { $0.$user.id })
        for (userID, mappings) in byUser where !failedThisRun.contains(userID) {
            guard let token = try await User.find(userID, on: db)?.tmdbToken, !token.isEmpty else {
                fail(userID, TMDBError.missingToken.description)
                continue
            }
            let tmdb = provider.make(token)
            let catalog = CatalogService(db: db, tmdb: tmdb)
            do {
                for mapping in mappings {
                    try await resolve(mapping, tmdb: tmdb, catalog: catalog)
                    changed = true
                }
            } catch let error as TMDBError {
                fail(userID, "TMDB nicht erreichbar: \(error)")
                logger.warning("Matching for one user stopped, TMDB error: \(error)")
            } catch {
                fail(userID, "Zuordnung fehlgeschlagen: \(error)")
                logger.error("Matching for one user failed: \(error)")
            }
        }
        return (changed, Set(byUser.keys))
    }

    private func fail(_ userID: UUID, _ message: String) {
        failedThisRun.insert(userID)
        errors[userID] = message
    }

    /// TMDB lookups happen outside the lock; the result is only written if the user has not
    /// decided on this mapping in the meantime (still `pending`).
    private func resolve(_ mapping: NetflixMapping, tmdb: any TMDBClient, catalog: CatalogService) async throws {
        let results = try await tmdb.search(mapping.netflixName, kind: mapping.titleKind)
        var titleID: UUID?
        if let hit = autoMatch(candidate: mapping.netflixName, in: results) {
            do {
                titleID = try await catalog.title(kind: mapping.titleKind, tmdbID: hit.id).requireID()
            } catch TMDBError.notFound {
                titleID = nil
            }
        }
        let mappingID = try mapping.requireID()
        try await locked {
            guard let fresh = try await NetflixMapping.find(mappingID, on: db), fresh.mappingStatus == .pending else { return }
            if let titleID {
                fresh.$title.id = titleID
                fresh.status = MappingStatus.auto.rawValue
            } else {
                fresh.status = MappingStatus.review.rawValue
                fresh.candidateResults = Array(results.prefix(5))
            }
            try await fresh.save(on: db)
            if titleID == nil && fresh.titleKind == .movie {
                try await redirectFallbackRows(from: fresh)
            }
        }
    }

    /// Single "X: Y" rows tried as a movie first: no clear movie → treat them as an episode of show X.
    private func redirectFallbackRows(from movieMapping: NetflixMapping) async throws {
        let mappingID = try movieMapping.requireID()
        let rows = try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID).filter(\.$parsedKind == "episode").all()
        for row in rows {
            let show = try await mapping(userID: row.$user.id, name: row.showName ?? row.rawTitle, kind: .tv)
            row.$mapping.id = try show.requireID()
            try await row.save(on: db)
        }
        if try await NetflixRow.query(on: db).filter(\.$mapping.$id == mappingID).count() == 0 {
            try await movieMapping.delete(on: db)
        }
    }

    // MARK: Step 3 – ignored names

    private func ignoreRowsOfIgnoredMappings() async throws {
        try await locked { try await ignoreRowsLocked() }
    }

    private func ignoreRowsLocked() async throws {
        let ignored = try await NetflixMapping.query(on: db).filter(\.$status == MappingStatus.ignored.rawValue).all().compactMap(\.id)
        guard !ignored.isEmpty else { return }
        try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue).filter(\.$mapping.$id ~~ ignored)
            .set(\.$status, to: RowStatus.ignored.rawValue).update()
    }

    // MARK: Step 4 – episodes / movies

    private func matchRows() async throws -> (Int, Int) {
        let resolvedIDs = try await NetflixMapping.query(on: db)
            .filter(\.$status ~~ [MappingStatus.auto.rawValue, MappingStatus.confirmed.rawValue]).filter(\.$title.$id != nil)
            .all().compactMap(\.id)
        guard !resolvedIDs.isEmpty else { return (0, 0) }
        let groups = Set(try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue)
            .filter(\.$mapping.$id ~~ resolvedIDs).all().compactMap(\.$mapping.id))
        var matched = 0, unmatched = 0
        for mappingID in groups {
            let (m, u) = try await locked { try await matchGroup(mappingID) }
            matched += m
            unmatched += u
        }
        return (matched, unmatched)
    }

    /// Matches one mapping's pending rows, re-reading mapping and rows under the lock so a
    /// decision the user made in the meantime is honoured.
    private func matchGroup(_ mappingID: UUID) async throws -> (Int, Int) {
        guard let mapping = try await NetflixMapping.find(mappingID, on: db),
              [.auto, .confirmed].contains(mapping.mappingStatus), let titleID = mapping.$title.id else { return (0, 0) }
        let rows = try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue)
            .filter(\.$mapping.$id == mappingID).all()
        guard !rows.isEmpty else { return (0, 0) }
        let catalog = CatalogService(db: db, tmdb: MissingTokenTMDBClient())   // cache reads only
        let candidates: [EpisodeCandidate] = mapping.titleKind == .movie ? [] : try await catalog.episodes(of: titleID).map {
            EpisodeCandidate(id: try $0.requireID(), season: $0.season, number: $0.number, name: $0.name)
        }
        var matched = 0, unmatched = 0
        for row in rows {
            let episodeIDs: [UUID?] = mapping.titleKind == .movie
                ? [nil]
                : matchEpisodes(title: row.episodeTitle ?? row.rawTitle, season: row.seasonNumber, in: candidates)
            if episodeIDs.isEmpty {
                row.status = RowStatus.unmatched.rawValue
                unmatched += 1
            } else {
                var first: UUID?
                for episodeID in episodeIDs {
                    let watch = try await watches.recordImportedWatch(userID: row.$user.id, titleID: titleID, episodeID: episodeID, day: row.watchedOn)
                    if first == nil { first = watch.id }
                }
                row.$watch.id = first
                row.status = RowStatus.matched.rawValue
                matched += 1
            }
            try await row.save(on: db)
        }
        return (matched, unmatched)
    }

    private func awaitingReviewCount() async throws -> Int {
        let review = try await NetflixMapping.query(on: db).filter(\.$status == MappingStatus.review.rawValue).all().compactMap(\.id)
        guard !review.isEmpty else { return 0 }
        return try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue).filter(\.$mapping.$id ~~ review).count()
    }
}

struct MatchingWorkerLifecycle: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        await application.matchingWorker.kick()
    }
}
