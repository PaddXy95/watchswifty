import Foundation

/// Whether a title is a series or a movie; the raw values are TMDB's path segments.
enum TitleKind: String, Codable, Sendable, CaseIterable {
    case tv, movie
}

/// A series or movie from a TMDB search or find result.
struct TMDBSearchResult: Codable, Sendable, Equatable {
    let id: Int
    let kind: TitleKind
    let name: String
    let originalName: String?
    /// Year of the first air date or release date.
    let year: Int?
    let posterPath: String?
}

/// Series details from TMDB (`GET /tv/{id}`).
struct TMDBSeries: Sendable, Equatable {
    let id: Int
    let name: String
    let originalName: String?
    let year: Int?
    let posterPath: String?
    /// TMDB's production status, e.g. `Returning Series` or `Ended`.
    let status: String?
    /// Numbers of all seasons TMDB lists for the series.
    let seasonNumbers: [Int]
    var overview: String? = nil
    /// Typical episode length in minutes (first of `episode_run_time`); nil when TMDB has none.
    var episodeRunTime: Int? = nil
    /// TMDB genre ids (TV list), see `Genre.from(tmdbIDs:)`.
    var genreIDs: [Int] = []
}

/// One episode of a season from TMDB (`GET /tv/{id}/season/{n}`).
struct TMDBEpisode: Sendable, Equatable {
    let id: Int
    let season: Int
    let number: Int
    let name: String
    /// Air date as `YYYY-MM-DD`; nil when unknown.
    let airDate: String?
    var overview: String? = nil
    /// Minutes; nil when TMDB has none.
    var runtime: Int? = nil
}

/// Movie details from TMDB (`GET /movie/{id}`).
struct TMDBMovie: Sendable, Equatable {
    let id: Int
    let name: String
    let originalName: String?
    let year: Int?
    let posterPath: String?
    var overview: String? = nil
    var imdbID: String? = nil
    /// Minutes; nil when TMDB has none.
    var runtime: Int? = nil
    /// TMDB genre ids (movie list), see `Genre.from(tmdbIDs:)`.
    var genreIDs: [Int] = []
}

/// Titles TMDB knows under an external id (`GET /find/{id}`); an episode id yields its series in `episodeShowIDs`.
struct TMDBFindResult: Sendable, Equatable {
    var movies: [TMDBSearchResult] = []
    var series: [TMDBSearchResult] = []
    var episodeShowIDs: [Int] = []
}

/// How a title is offered at a streaming service (TMDB „watch providers“, data by JustWatch).
enum OfferKind: String, Codable, Sendable, CaseIterable {
    /// `flatrate`: included in a subscription; `free`: free; `ads`: free with ads; `rent`/`buy`: paid.
    case flatrate, free, ads, rent, buy
}

/// One offer of a title in one country.
struct TMDBOffer: Sendable, Equatable {
    let providerID: Int
    let name: String
    let logoPath: String?
    /// TMDB's order of services (smaller first); `Int.max` when TMDB has none.
    let displayPriority: Int
    let kind: OfferKind
}

/// Offers of a title (`GET /{movie|tv}/{id}/watch/providers`), keyed by country code.
struct TMDBWatchProviders: Sendable, Equatable {
    /// Link to TMDB's watch page for the title, per country code.
    var links: [String: String] = [:]
    /// All offers per country code.
    var offers: [String: [TMDBOffer]] = [:]
}

/// A streaming service of a country (`GET /watch/providers/{movie|tv}?watch_region=`).
struct TMDBProviderInfo: Sendable, Equatable {
    let providerID: Int
    let name: String
    let logoPath: String?
    let displayPriority: Int
}

/// A country with watch provider data (`GET /watch/providers/regions`).
struct TMDBRegion: Sendable, Equatable {
    let code: String
    let name: String
}

/// A failed TMDB request; `description` is the German text shown to users.
enum TMDBError: Error, Equatable, CustomStringConvertible {
    /// `missingToken`: the user has no TMDB token; `unauthorized`: 401; `notFound`: 404; `rateLimited`: 429 after the
    /// retries; `invalidResponse`: the body could not be decoded.
    case missingToken, unauthorized, notFound, rateLimited, invalidResponse
    /// Any other unexpected HTTP status code.
    case http(UInt)
    /// The request failed before a response arrived (with the underlying error's description).
    case network(String)

    /// German error text for the UI.
    var description: String {
        switch self {
        case .missingToken: "Kein TMDB-Token hinterlegt – bitte unter Konto eintragen."
        case .unauthorized: "Token ungültig (HTTP 401)"
        case .notFound: "nicht gefunden (HTTP 404)"
        case .rateLimited: "Anfragelimit erreicht (HTTP 429)"
        case .invalidResponse: "unerwartete Antwort von TMDB"
        case .http(let code): "HTTP \(code)"
        case .network(let message): message
        }
    }
}

/// Access to the TMDB API with one user's token.
///
/// The live implementation is `LiveTMDBClient`; tests use a fake and users without a token get
/// `MissingTokenTMDBClient`. All methods throw `TMDBError`.
protocol TMDBClient: Sendable {
    /// Checks that the token is accepted (`GET /authentication`).
    /// - Throws: `TMDBError.unauthorized` when TMDB rejects the token, other `TMDBError`s when TMDB fails.
    func validate() async throws
    /// Searches series or movies by name (`GET /search/{tv|movie}`, no adult titles).
    /// - Parameters:
    ///   - query: The search text.
    ///   - kind: Whether to search series or movies.
    /// - Returns: The matching titles in TMDB's order.
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult]
    /// Searches series and movies at once (`GET /search/multi`); people are skipped.
    /// - Parameter query: The search text.
    /// - Returns: The matching titles in TMDB's order.
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult]
    /// Loads a series' details (`GET /tv/{id}`).
    /// - Parameter id: The TMDB series ID.
    /// - Returns: The series.
    func series(id: Int) async throws -> TMDBSeries
    /// Loads the episodes of one season (`GET /tv/{id}/season/{number}`).
    /// - Parameters:
    ///   - seriesID: The TMDB series ID.
    ///   - number: The season number.
    /// - Returns: The season's episodes.
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode]
    /// Loads a movie's details (`GET /movie/{id}`).
    /// - Parameter id: The TMDB movie ID.
    /// - Returns: The movie.
    func movie(id: Int) async throws -> TMDBMovie
    /// IMDb id of a series (`GET /tv/{id}/external_ids`); nil when TMDB has none.
    /// - Parameter id: The TMDB series ID.
    /// - Returns: The IMDb ID, e.g. `tt0903747`, or nil.
    func seriesIMDbID(id: Int) async throws -> String?
    /// Titles with this IMDb id (`GET /find/{id}?external_source=imdb_id`).
    /// - Parameter imdbID: The IMDb ID of a movie, series or episode.
    /// - Returns: The matching movies and series, and the series IDs of matching episodes.
    func find(imdbID: String) async throws -> TMDBFindResult
    /// Offers of a title in all countries (`GET /{movie|tv}/{id}/watch/providers`).
    /// - Parameters:
    ///   - kind: Whether the title is a series or a movie.
    ///   - id: The TMDB title ID.
    /// - Returns: The offers and TMDB watch page links per country.
    func watchProviders(kind: TitleKind, id: Int) async throws -> TMDBWatchProviders
    /// Streaming services of a country (`GET /watch/providers/{movie|tv}?watch_region=`).
    /// - Parameters:
    ///   - kind: Whether to list services for series or movies.
    ///   - region: ISO 3166-1 country code.
    /// - Returns: The country's services.
    func providers(kind: TitleKind, region: String) async throws -> [TMDBProviderInfo]
    /// Countries with watch provider data (`GET /watch/providers/regions`).
    /// - Returns: The countries with their native (or English) names.
    func providerRegions() async throws -> [TMDBRegion]
}

/// Builds a TMDB client for one user's token.
struct TMDBProvider: Sendable {
    /// Creates a client for a TMDB token.
    let make: @Sendable (String) -> any TMDBClient

    /// Creates a provider.
    /// - Parameter make: Builds a client for a token.
    init(make: @escaping @Sendable (String) -> any TMDBClient) {
        self.make = make
    }
}

/// Stand-in for users without a token: every call fails with `.missingToken`.
struct MissingTokenTMDBClient: TMDBClient {
    /// Always throws `TMDBError.missingToken`.
    func validate() async throws { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult] { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult] { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func series(id: Int) async throws -> TMDBSeries { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode] { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func movie(id: Int) async throws -> TMDBMovie { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func seriesIMDbID(id: Int) async throws -> String? { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func find(imdbID: String) async throws -> TMDBFindResult { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func watchProviders(kind: TitleKind, id: Int) async throws -> TMDBWatchProviders { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func providers(kind: TitleKind, region: String) async throws -> [TMDBProviderInfo] { throw TMDBError.missingToken }
    /// Always throws `TMDBError.missingToken`.
    func providerRegions() async throws -> [TMDBRegion] { throw TMDBError.missingToken }
}
