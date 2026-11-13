import Fluent
import Foundation
import Vapor

/// Progress of one user's reload of all their titles from TMDB (in memory only; gone after a restart).
struct LibraryRefreshState: Sendable, Equatable {
    var running = false
    /// Titles handled so far, successful or not.
    var done = 0
    var total = 0
    var failed = 0
    var finishedAt: Date?
    /// Why the run stopped early (e.g. an invalid token); nil when it went through.
    var error: String?

    static let idle = LibraryRefreshState()

    /// Titles reloaded successfully.
    var refreshed: Int { done - failed }
}

/// Every title of the user – watched, or with a `user_titles` row (rated, hidden, followed) –, series and movies.
/// Titles lacking runtime or genres come first so newly added data shows up soonest; each group by TMDB id.
func libraryRefreshTitles(userID: UUID, on db: any Database) async throws -> [Title] {
    let watched = try await Watch.query(on: db).filter(\.$user.$id == userID).unique().all(\.$title.$id)
    let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).all(\.$title.$id)
    let ids = Array(Set(watched).union(entries))
    guard !ids.isEmpty else { return [] }
    let titles = try await Title.query(on: db).filter(\.$id ~~ ids).all()
    func lacksDetails(_ title: Title) -> Bool { title.runtime == nil || title.genres == nil }
    return titles.sorted { a, b in
        if lacksDetails(a) != lacksDetails(b) { return lacksDetails(a) }
        if a.tmdbID != b.tmdbID { return a.tmdbID < b.tmdbID }
        return a.kind < b.kind
    }
}

/// Reloads all titles of a user from TMDB in the background with the user's own token, one run per user at a time
/// (Konto → „Alle Daten von TMDB neu laden“ and `POST /v1/library/refresh`).
actor LibraryRefreshWorker {
    private let db: any Database
    private let provider: TMDBProvider
    private let logger: Logger
    private let matching: MatchingWorker
    private var states: [UUID: LibraryRefreshState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(db: any Database, provider: TMDBProvider, logger: Logger, matching: MatchingWorker) {
        self.db = db
        self.provider = provider
        self.logger = logger
        self.matching = matching
    }

    func state(userID: UUID) -> LibraryRefreshState {
        states[userID] ?? .idle
    }

    /// Starts a run, or returns the state of the one already running for this user.
    func start(userID: UUID, token: String) async throws -> LibraryRefreshState {
        if let current = states[userID], current.running { return current }
        let titles = try await libraryRefreshTitles(userID: userID, on: db)
        // A second start may have begun while the titles were loading (actor reentrancy).
        if let current = states[userID], current.running { return current }
        let state = LibraryRefreshState(running: true, total: titles.count)
        states[userID] = state
        tasks[userID] = Task { await self.run(userID: userID, titles: titles, token: token) }
        return state
    }

    /// Waits until the user's current run has finished (tests).
    func wait(userID: UUID) async {
        await tasks[userID]?.value
    }

    /// Stops every run and waits for them (shutdown: the database goes away with the app).
    func cancelAll() async {
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func run(userID: UUID, titles: [Title], token: String) async {
        let catalog = CatalogService(db: db, tmdb: provider.make(token))
        var requeued = 0
        for title in titles {
            if Task.isCancelled { break }
            do {
                try await catalog.refresh(title)
                if title.titleKind == .tv { requeued += try await requeueUnmatchedRows(titleID: title.requireID(), on: db) }
                states[userID]?.done += 1
            } catch TMDBError.unauthorized {
                states[userID]?.error = TMDBError.unauthorized.description
                break
            } catch {
                logger.warning("TMDB-Neuladen für \(title.name) fehlgeschlagen: \(error)")
                states[userID]?.done += 1
                states[userID]?.failed += 1
            }
        }
        states[userID]?.running = false
        states[userID]?.finishedAt = .now
        tasks[userID] = nil
        if requeued > 0 { await matching.kick() }
    }
}

extension Application {
    private struct LibraryRefreshKey: StorageKey { typealias Value = LibraryRefreshWorker }

    var libraryRefresh: LibraryRefreshWorker {
        get {
            guard let worker = storage[LibraryRefreshKey.self] else { fatalError("Library refresh not configured") }
            return worker
        }
        set { storage[LibraryRefreshKey.self] = newValue }
    }
}

/// Cancels running reloads on shutdown.
struct LibraryRefreshLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.libraryRefresh.cancelAll()
    }
}
