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
    private let tmdb: any TMDBClient
    private let logger: Logger
    private let enabled: Bool

    private(set) var isRunning = false
    private(set) var lastError: String?
    private var rerunRequested = false

    init(db: any Database, tmdb: any TMDBClient, logger: Logger, enabled: Bool) {
        self.db = db
        self.tmdb = tmdb
        self.logger = logger
        self.enabled = enabled
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
                lastError = "Zuordnung fehlgeschlagen: \(error)"
                logger.error("Matching failed: \(error)")
            }
        } while rerunRequested
        isRunning = false
    }

    private var catalog: CatalogService { CatalogService(db: db, tmdb: tmdb) }
    private var watches: WatchService { WatchService(db: db) }

    func processAll() async throws -> MatchingRunResult {
        var result = MatchingRunResult()
        do {
            var changed = true
            while changed {
                changed = false
                if try await assignMappings() { changed = true }
                if try await resolveMappings() { changed = true }
                try await ignoreRowsOfIgnoredMappings()
                let (matched, unmatched) = try await matchRows()
                result.matched += matched
                result.unmatched += unmatched
                if matched + unmatched > 0 { changed = true }
            }
            lastError = nil
        } catch let error as TMDBError {
            lastError = "TMDB nicht erreichbar: \(error)"
            logger.warning("Matching stopped, TMDB error: \(error)")
        }
        result.awaitingReview = try await awaitingReviewCount()
        return result
    }

    // MARK: Step 1 – mapping keys

    /// Gives every pending row without a mapping its (name, kind) mapping.
    private func assignMappings() async throws -> Bool {
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

    private func resolveMappings() async throws -> Bool {
        let pending = try await NetflixMapping.query(on: db).filter(\.$status == MappingStatus.pending.rawValue).all()
        for mapping in pending {
            let results = try await tmdb.search(mapping.netflixName, kind: mapping.titleKind)
            var resolved = false
            if let hit = autoMatch(candidate: mapping.netflixName, in: results) {
                do {
                    let title = try await catalog.title(kind: mapping.titleKind, tmdbID: hit.id)
                    mapping.$title.id = try title.requireID()
                    mapping.status = MappingStatus.auto.rawValue
                    resolved = true
                } catch TMDBError.notFound {
                    resolved = false
                }
            }
            if !resolved {
                mapping.status = MappingStatus.review.rawValue
                mapping.candidateResults = Array(results.prefix(5))
            }
            try await mapping.save(on: db)
            if !resolved && mapping.titleKind == .movie {
                try await redirectFallbackRows(from: mapping)
            }
        }
        return !pending.isEmpty
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
        let ignored = try await NetflixMapping.query(on: db).filter(\.$status == MappingStatus.ignored.rawValue).all().compactMap(\.id)
        guard !ignored.isEmpty else { return }
        try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue).filter(\.$mapping.$id ~~ ignored)
            .set(\.$status, to: RowStatus.ignored.rawValue).update()
    }

    // MARK: Step 4 – episodes / movies

    private func matchRows() async throws -> (Int, Int) {
        let resolved = try await NetflixMapping.query(on: db)
            .filter(\.$status ~~ [MappingStatus.auto.rawValue, MappingStatus.confirmed.rawValue]).filter(\.$title.$id != nil).all()
        guard !resolved.isEmpty else { return (0, 0) }
        let byID = Dictionary(resolved.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let rows = try await NetflixRow.query(on: db).filter(\.$status == RowStatus.pending.rawValue)
            .filter(\.$mapping.$id ~~ Array(byID.keys)).all()
        var matched = 0, unmatched = 0
        for (mappingID, mappingRows) in Dictionary(grouping: rows, by: { $0.$mapping.id! }) {
            guard let mapping = byID[mappingID], let titleID = mapping.$title.id else { continue }
            let candidates: [EpisodeCandidate] = mapping.titleKind == .movie ? [] : try await catalog.episodes(of: titleID).map {
                EpisodeCandidate(id: try $0.requireID(), season: $0.season, number: $0.number, name: $0.name)
            }
            for row in mappingRows {
                let episodeIDs: [UUID?]
                if mapping.titleKind == .movie {
                    episodeIDs = [nil]
                } else {
                    episodeIDs = matchEpisodes(title: row.episodeTitle ?? row.rawTitle, season: row.seasonNumber, in: candidates)
                }
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
