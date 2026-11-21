import Fluent
import Foundation
import SQLKit
import Vapor

/// One card on the „Weiterschauen“ (continue watching) shelf: a series with its next episode.
struct ContinueCard: Sendable {
    let titleID: UUID
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let rating: Int?
    let next: EpisodeInfo
    /// Aired, unwatched regular episodes from `next` onwards (including `next`).
    let remaining: Int
    /// Day of the newest dated watch; nil when all watches are undated.
    let lastWatchedOn: String?
    /// Service of the most recent watch that has one.
    let lastService: StreamingService?
    /// Service for the card's button: the most recently used one that has a link (see `watchLink(for:)`).
    let watchService: StreamingService?
    /// Later of the newest dated watch and the day the newest undated watch was recorded (see
    /// `ContinueWatchingService.lastActivity(_:)`).
    var lastActivityOn: String = ""
}

/// Builds the "Weiterschauen" shelf for one user (§5.2).
struct ContinueWatchingService {
    let db: any Database

    /// Later of the newest dated watch and the day the newest undated (bulk-marked) watch was made,
    /// so catching up after an old import keeps the series on the shelf.
    /// - Parameter watches: The watches of one series.
    /// - Returns: The day (`YYYY-MM-DD`), or nil without watches.
    static func lastActivity(_ watches: [WatchRow]) -> String? {
        let dated = watches.compactMap(\.watchedOn).max()
        let undatedDay = watches.filter { $0.watchedOn == nil }.compactMap(\.createdAt).max().map { CalendarDay.today(now: $0) }
        return [dated, undatedDay].compactMap { $0 }.max()
    }

    /// All cards: series that are not hidden and have an aired, unwatched regular episode after the highest watched one.
    ///
    /// Series with dated watches come first (newest day first), then series with only undated watches (newest recorded
    /// first).
    /// - Parameters:
    ///   - userID: The user.
    ///   - today: The current day (`YYYY-MM-DD`, see `AppConfig.today()`).
    /// - Returns: The cards in shelf order.
    /// - Throws: Database errors.
    func cards(userID: UUID, today: String) async throws -> [ContinueCard] {
        try await build(userID: userID, onlyTitle: nil, today: today)
    }

    /// The card of one series, e.g. to swap it in after its next episode was marked watched.
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleID: The series.
    ///   - today: The current day (`YYYY-MM-DD`).
    /// - Returns: The card, or nil when the series is caught up, hidden or not watched.
    /// - Throws: Database errors.
    func card(userID: UUID, titleID: UUID, today: String) async throws -> ContinueCard? {
        try await build(userID: userID, onlyTitle: titleID, today: today).first
    }

    /// Builds and sorts the cards, for all series or only `onlyTitle`.
    /// - Parameters:
    ///   - userID: The user.
    ///   - onlyTitle: Limits the result to this series, or nil for all.
    ///   - today: The current day (`YYYY-MM-DD`).
    /// - Returns: The cards in shelf order.
    /// - Throws: Database errors.
    private func build(userID: UUID, onlyTitle: UUID?, today: String) async throws -> [ContinueCard] {
        // Only series with an aired episode after the highest watched one get a card; their watches are all that is
        // read (caught-up series often hold most of a user's watches).
        let pendingByTitle = try await pendingEpisodes(userID: userID, onlyTitle: onlyTitle, today: today)
        guard !pendingByTitle.isEmpty else { return [] }
        let titles = try await TitleRow.series(Array(pendingByTitle.keys), on: db)
        let entryByTitle = try await EntryRow.all(userID: userID, titleIDs: titles.map(\.id), on: db)
        let shown = titles.filter { entryByTitle[$0.id]?.hidden != true }
        let watches = try await WatchRow.all(userID: userID, episodesOnly: true, titleIDs: shown.map(\.id), on: db)
        let watchesByTitle = Dictionary(grouping: watches, by: \.titleID)

        var result: [(card: ContinueCard, sortKey: (Int, String, Date))] = []
        for title in shown {
            let titleID = title.id
            let titleWatches = watchesByTitle[titleID] ?? []
            guard let (next, remaining) = pendingByTitle[titleID] else { continue }

            let lastDated = titleWatches.compactMap(\.watchedOn).max()
            let latestCreated = titleWatches.compactMap(\.createdAt).max() ?? .distantPast
            let byRecency = titleWatches.sorted { a, b in
                switch (a.watchedOn, b.watchedOn) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
                }
            }
            let card = ContinueCard(
                titleID: titleID, tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath,
                rating: entryByTitle[titleID]?.rating, next: next,
                remaining: remaining,
                lastWatchedOn: lastDated,
                lastService: byRecency.lazy.compactMap(\.service).first,
                watchService: byRecency.lazy.compactMap(\.service).first { $0.watchLink(for: title.name) != nil }
                    ?? (titleWatches.contains { $0.origin == .import } ? .netflix : nil),
                lastActivityOn: Self.lastActivity(titleWatches) ?? lastDated ?? CalendarDay.today(now: latestCreated)
            )
            // Dated series first (newest day first), then undated-only series by creation time.
            result.append((card, (lastDated == nil ? 1 : 0, lastDated ?? "", latestCreated)))
        }
        return result.sorted { a, b in
            if a.sortKey.0 != b.sortKey.0 { return a.sortKey.0 < b.sortKey.0 }
            if a.sortKey.1 != b.sortKey.1 { return a.sortKey.1 > b.sortKey.1 }
            return a.sortKey.2 > b.sortKey.2
        }.map(\.card)
    }

    /// Per series with something left to watch: the first aired regular episode after the highest watched regular
    /// episode (`nextEpisode(in:watched:today:)`) and how many aired ones there are from there on
    /// (`remainingAiredCount(in:from:watched:today:)`). Everything after the highest watched episode is unwatched, so SQL
    /// counts them and returns one row per series instead of every episode of every watched series.
    /// - Parameters:
    ///   - userID: The user.
    ///   - onlyTitle: Limits the result to this series, or nil for all.
    ///   - today: The current day (`YYYY-MM-DD`).
    /// - Returns: The next episode and remaining count, keyed by series; caught-up series are missing.
    /// - Throws: Database errors.
    private func pendingEpisodes(userID: UUID, onlyTitle: UUID?,
                                 today: String) async throws -> [UUID: (next: EpisodeInfo, remaining: Int)] {
        guard let sql = db as? any SQLDatabase else {
            let watches = try await WatchRow.all(userID: userID, episodesOnly: true, titleIDs: onlyTitle.map { [$0] }, on: db)
            let watched = Set(watches.compactMap(\.episodeID))
            return try await Episode.infos(ofTitles: Array(Set(watches.map(\.titleID))), on: db).compactMapValues { episodes in
                guard let next = nextEpisode(in: episodes, watched: watched, today: today) else { return nil }
                return (next, remainingAiredCount(in: episodes, from: next, watched: watched, today: today))
            }
        }
        /// One result row: the next episode of a series plus the remaining count.
        struct Row: Decodable {
            let id: UUID
            let title_id: UUID
            let season_number: Int
            let episode_number: Int
            let name: String
            let air_date: String?
            let runtime: Int?
            let remaining: Int
        }
        /// Season and episode as one sortable number.
        /// - Parameter table: The alias of the episodes table.
        /// - Returns: `season_number * 1000000 + episode_number`.
        func position(_ table: String) -> any SQLExpression {
            SQLGroupExpression(SQLBinaryExpression(
                SQLBinaryExpression(SQLColumn("season_number", table: table), .multiply, SQLLiteral.numeric("1000000")),
                .add, SQLColumn("episode_number", table: table)))
        }
        // Per series: the position of the highest watched regular episode.
        let highest = SQLSubquery.select { query in
            query
                .column(SQLColumn("title_id", table: "we"), as: "title_id")
                .column(SQLFunction("MAX", args: position("we")), as: "pos")
                .from(SQLAlias(SQLIdentifier(Watch.schema), as: SQLIdentifier("w")))
                .join(SQLAlias(SQLIdentifier(Episode.schema), as: SQLIdentifier("we")), method: SQLJoinMethod.inner,
                      on: SQLColumn("id", table: "we"), .equal, SQLColumn("episode_id", table: "w"))
                .where(SQLColumn("user_id", table: "w"), .equal, SQLBind(userID))
                .where(SQLColumn("season_number", table: "we"), .greaterThanOrEqual, SQLBind(1))
            if let onlyTitle { query.where(SQLColumn("title_id", table: "w"), .equal, SQLBind(onlyTitle)) }
            return query.groupBy(SQLColumn("title_id", table: "we"))
        }
        // Per series: how many aired episodes come after it, and the position of the first.
        let pending = SQLSubquery.select { $0
            .column(SQLColumn("title_id", table: "e"), as: "title_id")
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "remaining")
            .column(SQLFunction("MIN", args: position("e")), as: "next_pos")
            .from(SQLAlias(SQLIdentifier(Episode.schema), as: SQLIdentifier("e")))
            .join(SQLAlias(highest, as: "h"), method: SQLJoinMethod.inner,
                  on: SQLColumn("title_id", table: "h"), .equal, SQLColumn("title_id", table: "e"))
            .where(position("e"), .greaterThan, SQLColumn("pos", table: "h"))
            .where(SQLColumn("air_date", table: "e"), .isNot, SQLLiteral.null)
            .where(SQLColumn("air_date", table: "e"), .lessThanOrEqual, SQLBind(today))
            .groupBy(SQLColumn("title_id", table: "e"))
        }
        let rows = try await sql.select()
            .column(SQLColumn("id", table: "n"), as: "id")
            .column(SQLColumn("title_id", table: "n"), as: "title_id")
            .column(SQLColumn("season_number", table: "n"), as: "season_number")
            .column(SQLColumn("episode_number", table: "n"), as: "episode_number")
            .column(SQLColumn("name", table: "n"), as: "name")
            .column(SQLColumn("air_date", table: "n"), as: "air_date")
            .column(SQLColumn("runtime", table: "n"), as: "runtime")
            .column(SQLColumn("remaining", table: "p"), as: "remaining")
            .from(SQLAlias(pending, as: "p"))
            .join(SQLAlias(SQLIdentifier(Episode.schema), as: SQLIdentifier("n")), method: SQLJoinMethod.inner,
                  on: SQLBinaryExpression(
                    SQLBinaryExpression(SQLColumn("title_id", table: "n"), .equal, SQLColumn("title_id", table: "p")),
                    .and, SQLBinaryExpression(position("n"), .equal, SQLColumn("next_pos", table: "p"))))
            .all(decoding: Row.self)
        return Dictionary(rows.map { row in
            (row.title_id, (EpisodeInfo(id: row.id, season: row.season_number, number: row.episode_number, name: row.name,
                                        airDate: row.air_date, runtime: row.runtime), row.remaining))
        }, uniquingKeysWith: { a, _ in a })
    }
}

/// The columns of a title that lists like „Weiterschauen“ and „Statistik“ need, read without building Fluent models.
struct TitleRow: Sendable {
    let id: UUID
    let tmdbID: Int
    let kind: TitleKind
    let name: String
    let posterPath: String?
    /// See `Title.runtime`.
    let runtime: Int?
    /// See `Title.genres`.
    let genres: String?

    /// Copies the columns of a loaded title.
    /// - Parameter title: A saved title.
    /// - Throws: An error when the title has no ID.
    init(_ title: Title) throws {
        self.init(id: try title.requireID(), tmdbID: title.tmdbID, kind: title.titleKind, name: title.name,
                  posterPath: title.posterPath, runtime: title.runtime, genres: title.genres)
    }

    /// Creates a row from its columns.
    /// - Parameters:
    ///   - id: The title's ID.
    ///   - tmdbID: The TMDB ID.
    ///   - kind: Series or movie.
    ///   - name: The title name.
    ///   - posterPath: The TMDB poster path.
    ///   - runtime: The stored runtime in minutes.
    ///   - genres: The stored genre list.
    init(id: UUID, tmdbID: Int, kind: TitleKind, name: String, posterPath: String?, runtime: Int?, genres: String?) {
        self.id = id
        self.tmdbID = tmdbID
        self.kind = kind
        self.name = name
        self.posterPath = posterPath
        self.runtime = runtime
        self.genres = genres
    }

    /// The stored genres decoded; nil when not loaded yet.
    var genreList: [Genre]? { Genre.list(genres) }

    /// The given titles; `kind` limits them to series or movies.
    /// - Parameters:
    ///   - ids: The title IDs; an empty array returns no rows.
    ///   - kind: Only series or only movies, or nil for both.
    ///   - db: The database; SQL databases get a plain projection, others fall back to Fluent models.
    /// - Returns: The found titles, in no particular order.
    /// - Throws: Database errors.
    static func all(_ ids: [UUID], kind: TitleKind? = nil, on db: any Database) async throws -> [TitleRow] {
        guard !ids.isEmpty else { return [] }
        guard let sql = db as? any SQLDatabase else {
            var query = Title.query(on: db).filter(\.$id ~~ ids)
            if let kind { query = query.filter(\.$kind == kind.rawValue) }
            return try await query.all().map(TitleRow.init)
        }
        /// The raw SQL row, with column names as stored.
        struct Row: Decodable {
            let id: UUID
            let tmdb_id: Int
            let kind: String
            let name: String
            let poster_path: String?
            let runtime: Int?
            let genres: String?
        }
        var query = sql.select()
            .columns("id", "tmdb_id", "kind", "name", "poster_path", "runtime", "genres")
            .from(Title.schema)
            .where(SQLColumn("id"), .in, SQLBind.group(ids))
        if let kind { query = query.where(SQLColumn("kind"), .equal, SQLBind(kind.rawValue)) }
        return try await query.all(decoding: Row.self).map { row in
            TitleRow(id: row.id, tmdbID: row.tmdb_id, kind: TitleKind(rawValue: row.kind) ?? .tv, name: row.name,
                     posterPath: row.poster_path, runtime: row.runtime, genres: row.genres)
        }
    }

    /// The given titles that are series.
    /// - Parameters:
    ///   - ids: The title IDs.
    ///   - db: The database.
    /// - Returns: The found series.
    /// - Throws: Database errors.
    static func series(_ ids: [UUID], on db: any Database) async throws -> [TitleRow] {
        try await all(ids, kind: .tv, on: db)
    }
}

/// A user's rating and „Ausgeblendet“ (hidden) flag of a title, read without building Fluent models.
struct EntryRow: Sendable {
    let rating: Int?
    let hidden: Bool

    /// Keyed by title; `titleIDs` nil = all of the user's entries.
    /// - Parameters:
    ///   - userID: The user.
    ///   - titleIDs: Limits the result to these titles; an empty array returns no entries.
    ///   - db: The database.
    /// - Returns: The user's entries keyed by title ID.
    /// - Throws: Database errors.
    static func all(userID: UUID, titleIDs: [UUID]? = nil, on db: any Database) async throws -> [UUID: EntryRow] {
        if let titleIDs, titleIDs.isEmpty { return [:] }
        let rows: [(UUID, EntryRow)]
        if let sql = db as? any SQLDatabase {
            /// The raw SQL row, with column names as stored.
            struct Row: Decodable {
                let title_id: UUID
                let rating: Int?
                let hidden: Bool
            }
            var query = sql.select()
                .columns("title_id", "rating", "hidden")
                .from(UserTitle.schema)
                .where(SQLColumn("user_id"), .equal, SQLBind(userID))
            if let titleIDs { query = query.where(SQLColumn("title_id"), .in, SQLBind.group(titleIDs)) }
            rows = try await query.all(decoding: Row.self).map { ($0.title_id, EntryRow(rating: $0.rating, hidden: $0.hidden)) }
        } else {
            var query = UserTitle.query(on: db).filter(\.$user.$id == userID)
            if let titleIDs { query = query.filter(\.$title.$id ~~ titleIDs) }
            rows = try await query.all().map { ($0.$title.id, EntryRow(rating: $0.rating, hidden: $0.hidden)) }
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }
}
