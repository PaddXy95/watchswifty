import Foundation
import NIOCore
import Vapor

/// `TMDBClient` that calls the TMDB API v3 with a user's bearer token.
///
/// All clients share one `RateLimiter`, so the whole server stays within one TMDB request budget; a 429 is retried up
/// to three times after the `Retry-After` delay. Malformed bodies become `TMDBError.invalidResponse`.
struct LiveTMDBClient: TMDBClient {
    /// Base address of the TMDB API v3.
    static let baseURL = "https://api.themoviedb.org/3"

    /// HTTP client used for the requests.
    let client: any Client
    /// The user's TMDB API read access token (sent as bearer token).
    let token: String
    /// Language of TMDB texts, sent as `language` on every request (e.g. `de-DE`).
    let language: String
    /// Rate limiter shared by all users' clients.
    let limiter: RateLimiter

    // MARK: TMDBClient

    /// Checks the token with `GET /authentication`.
    /// - Throws: `TMDBError.unauthorized` when TMDB rejects the token, other `TMDBError`s when TMDB fails.
    func validate() async throws {
        _ = try await get("authentication", [:])
    }

    /// Searches series or movies by name (`GET /search/{tv|movie}`, no adult titles).
    /// - Parameters:
    ///   - query: The search text.
    ///   - kind: Whether to search series or movies.
    /// - Returns: The matching titles in TMDB's order.
    /// - Throws: `TMDBError`.
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult] {
        let data = try await get("search/\(kind.rawValue)", ["query": query, "include_adult": "false"])
        return try Self.decoding { try Self.decodeSearch(data, kind: kind) }
    }

    /// Searches series and movies at once (`GET /search/multi`); people are skipped.
    /// - Parameter query: The search text.
    /// - Returns: The matching titles in TMDB's order.
    /// - Throws: `TMDBError`.
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult] {
        let data = try await get("search/multi", ["query": query, "include_adult": "false"])
        return try Self.decoding { try Self.decodeMulti(data) }
    }

    /// Loads a series' details (`GET /tv/{id}`).
    /// - Parameter id: The TMDB series ID.
    /// - Returns: The series.
    /// - Throws: `TMDBError` (`.notFound` for an unknown ID).
    func series(id: Int) async throws -> TMDBSeries {
        let data = try await get("tv/\(id)", [:])
        return try Self.decoding { try Self.decodeSeries(data) }
    }

    /// Loads the episodes of one season (`GET /tv/{id}/season/{number}`).
    /// - Parameters:
    ///   - seriesID: The TMDB series ID.
    ///   - number: The season number.
    /// - Returns: The season's episodes.
    /// - Throws: `TMDBError` (`.notFound` for an unknown season).
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode] {
        let data = try await get("tv/\(seriesID)/season/\(number)", [:])
        return try Self.decoding { try Self.decodeSeason(data) }
    }

    /// Loads a movie's details (`GET /movie/{id}`).
    /// - Parameter id: The TMDB movie ID.
    /// - Returns: The movie.
    /// - Throws: `TMDBError` (`.notFound` for an unknown ID).
    func movie(id: Int) async throws -> TMDBMovie {
        let data = try await get("movie/\(id)", [:])
        return try Self.decoding { try Self.decodeMovie(data) }
    }

    /// Maps malformed bodies (proxies, captive portals, API changes) to `.invalidResponse`.
    /// - Parameter body: The decoding work.
    /// - Returns: The decoded value.
    /// - Throws: `TMDBError.invalidResponse` instead of a `DecodingError`; other errors unchanged.
    static func decoding<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch is DecodingError { throw TMDBError.invalidResponse }
    }

    /// Loads a series' IMDb ID (`GET /tv/{id}/external_ids`).
    /// - Parameter id: The TMDB series ID.
    /// - Returns: The IMDb ID, or nil when TMDB has none.
    /// - Throws: `TMDBError`.
    func seriesIMDbID(id: Int) async throws -> String? {
        let data = try await get("tv/\(id)/external_ids", [:])
        return try Self.decoding { try Self.decodeExternalIDs(data) }
    }

    /// Finds titles by IMDb ID (`GET /find/{id}?external_source=imdb_id`).
    /// - Parameter imdbID: The IMDb ID of a movie, series or episode.
    /// - Returns: The matching movies and series, and the series IDs of matching episodes.
    /// - Throws: `TMDBError`.
    func find(imdbID: String) async throws -> TMDBFindResult {
        let data = try await get("find/\(imdbID)", ["external_source": "imdb_id"])
        return try Self.decoding { try Self.decodeFind(data) }
    }

    /// Loads a title's offers in all countries (`GET /{movie|tv}/{id}/watch/providers`).
    /// - Parameters:
    ///   - kind: Whether the title is a series or a movie.
    ///   - id: The TMDB title ID.
    /// - Returns: The offers and TMDB watch page links per country.
    /// - Throws: `TMDBError`, `.invalidResponse` when the body has no `results`.
    func watchProviders(kind: TitleKind, id: Int) async throws -> TMDBWatchProviders {
        let data = try await get("\(kind.rawValue)/\(id)/watch/providers", [:])
        return try Self.decoding { try Self.decodeWatchProviders(data) }
    }

    /// Lists a country's streaming services (`GET /watch/providers/{movie|tv}?watch_region=`).
    /// - Parameters:
    ///   - kind: Whether to list services for series or movies.
    ///   - region: ISO 3166-1 country code.
    /// - Returns: The country's services.
    /// - Throws: `TMDBError`.
    func providers(kind: TitleKind, region: String) async throws -> [TMDBProviderInfo] {
        let data = try await get("watch/providers/\(kind.rawValue)", ["watch_region": region])
        return try Self.decoding { try Self.decodeProviderList(data) }
    }

    /// Lists the countries with watch provider data (`GET /watch/providers/regions`).
    /// - Returns: The countries with their native (or English) names.
    /// - Throws: `TMDBError`.
    func providerRegions() async throws -> [TMDBRegion] {
        let data = try await get("watch/providers/regions", [:])
        return try Self.decoding { try Self.decodeRegions(data) }
    }

    // MARK: HTTP

    /// Sends a GET request after waiting for the shared rate limiter, retrying a 429 up to three times.
    /// - Parameters:
    ///   - path: API path below `baseURL`, without leading slash.
    ///   - query: Query parameters (`language` is added).
    /// - Returns: The body of a 2xx response.
    /// - Throws: `TMDBError.network` when the request fails, `.unauthorized` on 401, `.notFound` on 404, `.rateLimited`
    ///   when 429 persists, `.http` on other status codes.
    private func get(_ path: String, _ query: [String: String]) async throws -> Data {
        let uri = Self.url(path: path, query: query, language: language)
        var attempt = 1
        while true {
            try await limiter.acquire()
            let response: ClientResponse
            do {
                response = try await client.get(uri, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
            } catch {
                throw TMDBError.network(String(describing: error))
            }
            switch response.status.code {
            case 200..<300:
                return response.body.map { Data($0.readableBytesView) } ?? Data()
            case 401: throw TMDBError.unauthorized
            case 404: throw TMDBError.notFound
            default:
                if let delay = Self.retryDelay(status: response.status.code, retryAfter: response.headers.first(name: "Retry-After"), attempt: attempt) {
                    try await Task.sleep(for: delay)
                    attempt += 1
                    continue
                }
                throw response.status.code == 429 ? TMDBError.rateLimited : TMDBError.http(response.status.code)
            }
        }
    }

    /// Builds the request URL with sorted query parameters and `+` escaped as `%2B`.
    /// - Parameters:
    ///   - path: API path below `baseURL`, without leading slash.
    ///   - query: Query parameters.
    ///   - language: Value of the `language` parameter.
    /// - Returns: The full request URI.
    static func url(path: String, query: [String: String], language: String) -> URI {
        var components = URLComponents(string: "\(baseURL)/\(path)")!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        components.queryItems = items.sorted { $0.name < $1.name }
        // URLComponents leaves "+" unescaped in queries; TMDB would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return URI(string: components.string!)
    }

    /// Delay before retrying a 429, or nil when the request must not be retried (max 3 retries).
    /// - Parameters:
    ///   - status: The response status code.
    ///   - retryAfter: The `Retry-After` header (seconds); 2 seconds when missing or not a number.
    ///   - attempt: The 1-based number of the attempt that just failed.
    /// - Returns: The delay, or nil.
    static func retryDelay(status: UInt, retryAfter: String?, attempt: Int) -> Duration? {
        guard status == 429, attempt <= 3 else { return nil }
        return .seconds(retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 2)
    }

    // MARK: Decoding

    /// A TMDB result page (`results` array) of search items.
    private struct ResultList: Decodable { let results: [Item] }
    /// A search or find item; series carry `name`/`first_air_date`, movies `title`/`release_date`.
    private struct Item: Decodable {
        let id: Int
        let media_type: String?
        let name: String?
        let original_name: String?
        let first_air_date: String?
        let title: String?
        let original_title: String?
        let release_date: String?
        let poster_path: String?

        /// Converts the item into a search result of the given kind.
        /// - Parameter kind: Whether to read the series or the movie fields.
        /// - Returns: The result, or nil when the kind's name field is missing.
        func result(kind: TitleKind) -> TMDBSearchResult? {
            switch kind {
            case .tv:
                guard let name else { return nil }
                return TMDBSearchResult(id: id, kind: .tv, name: name, originalName: original_name, year: year(first_air_date), posterPath: poster_path)
            case .movie:
                guard let title else { return nil }
                return TMDBSearchResult(id: id, kind: .movie, name: title, originalName: original_title, year: year(release_date), posterPath: poster_path)
            }
        }
    }

    /// Extracts the year from a TMDB date.
    /// - Parameter date: A `YYYY-MM-DD` date.
    /// - Returns: The year, or nil for a missing or too short date.
    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// Treats zero and negative numbers (TMDB's "unknown") as missing.
    /// - Parameter value: A number from TMDB.
    /// - Returns: The value when positive, else nil.
    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Treats an empty string as missing.
    /// - Parameter value: A string from TMDB.
    /// - Returns: The value when non-empty, else nil.
    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Decodes a search response.
    /// - Parameters:
    ///   - data: The response body.
    ///   - kind: Whether the results are series or movies.
    /// - Returns: The results that have a name.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeSearch(_ data: Data, kind: TitleKind) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { $0.result(kind: kind) }
    }

    /// Decodes a `/find` response.
    /// - Parameter data: The response body.
    /// - Returns: Movies, series and the series IDs of found episodes.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeFind(_ data: Data) throws -> TMDBFindResult {
        /// A found episode; only its series ID is used.
        struct EpisodeRef: Decodable { let show_id: Int? }
        /// The result lists of a `/find` response.
        struct Found: Decodable {
            let movie_results: [Item]?
            let tv_results: [Item]?
            let tv_episode_results: [EpisodeRef]?
        }
        let found = try JSONDecoder().decode(Found.self, from: data)
        return TMDBFindResult(movies: (found.movie_results ?? []).compactMap { $0.result(kind: .movie) },
                              series: (found.tv_results ?? []).compactMap { $0.result(kind: .tv) },
                              episodeShowIDs: (found.tv_episode_results ?? []).compactMap(\.show_id))
    }

    /// Decodes a multi search response, keeping only series and movies.
    /// - Parameter data: The response body.
    /// - Returns: The series and movie results.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeMulti(_ data: Data) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { item in
            guard let raw = item.media_type, let kind = TitleKind(rawValue: raw) else { return nil }
            return item.result(kind: kind)
        }
    }

    /// A genre entry of a series or movie; only its ID is used.
    private struct GenreRef: Decodable { let id: Int }

    /// Decodes a series details response.
    /// - Parameter data: The response body.
    /// - Returns: The series; blank overview and non-positive run time become nil.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeSeries(_ data: Data) throws -> TMDBSeries {
        /// A season entry of the series details; only its number is used.
        struct Season: Decodable { let season_number: Int }
        /// The series details fields WatchSwifty uses.
        struct Series: Decodable {
            let id: Int; let name: String; let original_name: String?; let first_air_date: String?
            let poster_path: String?; let status: String?; let seasons: [Season]?; let overview: String?
            let episode_run_time: [Int]?; let genres: [GenreRef]?
        }
        let s = try JSONDecoder().decode(Series.self, from: data)
        return TMDBSeries(id: s.id, name: s.name, originalName: s.original_name, year: year(s.first_air_date),
                          posterPath: s.poster_path, status: s.status, seasonNumbers: (s.seasons ?? []).map(\.season_number),
                          overview: blankToNil(s.overview), episodeRunTime: positive(s.episode_run_time?.first),
                          genreIDs: (s.genres ?? []).map(\.id))
    }

    /// Decodes a season response.
    /// - Parameter data: The response body.
    /// - Returns: The season's episodes; a missing name becomes empty, blank texts and non-positive run times nil.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeSeason(_ data: Data) throws -> [TMDBEpisode] {
        /// The episode fields WatchSwifty uses.
        struct Episode: Decodable {
            let id: Int; let episode_number: Int; let season_number: Int; let name: String?; let air_date: String?; let overview: String?
            let runtime: Int?
        }
        /// A season response; only its episodes are used.
        struct Season: Decodable { let episodes: [Episode]? }
        return try (JSONDecoder().decode(Season.self, from: data).episodes ?? []).map {
            TMDBEpisode(id: $0.id, season: $0.season_number, number: $0.episode_number, name: $0.name ?? "", airDate: blankToNil($0.air_date),
                        overview: blankToNil($0.overview), runtime: positive($0.runtime))
        }
    }

    /// Decodes an external IDs response.
    /// - Parameter data: The response body.
    /// - Returns: The IMDb ID, or nil when missing or blank.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeExternalIDs(_ data: Data) throws -> String? {
        /// The external IDs field WatchSwifty uses.
        struct IDs: Decodable { let imdb_id: String? }
        return blankToNil(try JSONDecoder().decode(IDs.self, from: data).imdb_id)
    }

    /// Decodes a movie details response.
    /// - Parameter data: The response body.
    /// - Returns: The movie; blank texts and non-positive run time become nil.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeMovie(_ data: Data) throws -> TMDBMovie {
        /// The movie details fields WatchSwifty uses.
        struct Movie: Decodable {
            let id: Int; let title: String; let original_title: String?; let release_date: String?; let poster_path: String?
            let overview: String?; let imdb_id: String?; let runtime: Int?; let genres: [GenreRef]?
        }
        let m = try JSONDecoder().decode(Movie.self, from: data)
        return TMDBMovie(id: m.id, name: m.title, originalName: m.original_title, year: year(m.release_date), posterPath: m.poster_path,
                         overview: blankToNil(m.overview), imdbID: blankToNil(m.imdb_id), runtime: positive(m.runtime),
                         genreIDs: (m.genres ?? []).map(\.id))
    }

    /// A streaming service entry in TMDB's watch provider responses.
    private struct ProviderRef: Decodable {
        let provider_id: Int; let provider_name: String; let logo_path: String?; let display_priority: Int?
    }

    /// Decodes a title's watch providers response.
    /// - Parameter data: The response body.
    /// - Returns: Links and offers per country; a missing `display_priority` becomes `Int.max`.
    /// - Throws: `DecodingError` for a malformed body or one without `results`.
    static func decodeWatchProviders(_ data: Data) throws -> TMDBWatchProviders {
        /// One country's offers, grouped by offer kind.
        struct Region: Decodable {
            let link: String?
            let flatrate: [ProviderRef]?; let free: [ProviderRef]?; let ads: [ProviderRef]?
            let rent: [ProviderRef]?; let buy: [ProviderRef]?
        }
        /// The watch providers response, keyed by country code.
        struct Response: Decodable { let results: [String: Region] }
        var result = TMDBWatchProviders()
        // A body without `results` is not „no offers anywhere“: it would wipe the stored offers and re-notify them later.
        for (code, region) in try JSONDecoder().decode(Response.self, from: data).results {
            if let link = region.link { result.links[code] = link }
            let groups: [(OfferKind, [ProviderRef]?)] = [(.flatrate, region.flatrate), (.free, region.free), (.ads, region.ads),
                                                         (.rent, region.rent), (.buy, region.buy)]
            result.offers[code] = groups.flatMap { kind, refs in
                (refs ?? []).map { TMDBOffer(providerID: $0.provider_id, name: $0.provider_name, logoPath: $0.logo_path,
                                             displayPriority: $0.display_priority ?? Int.max, kind: kind) }
            }
        }
        return result
    }

    /// Decodes a country's provider list response.
    /// - Parameter data: The response body.
    /// - Returns: The services; a missing `display_priority` becomes `Int.max`.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeProviderList(_ data: Data) throws -> [TMDBProviderInfo] {
        /// The provider list response.
        struct Response: Decodable { let results: [ProviderRef]? }
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).map {
            TMDBProviderInfo(providerID: $0.provider_id, name: $0.provider_name, logoPath: $0.logo_path,
                             displayPriority: $0.display_priority ?? Int.max)
        }
    }

    /// Decodes the regions response.
    /// - Parameter data: The response body.
    /// - Returns: The countries, named by native name, English name or code.
    /// - Throws: `DecodingError` for a malformed body.
    static func decodeRegions(_ data: Data) throws -> [TMDBRegion] {
        /// A country entry of the regions response.
        struct Region: Decodable { let iso_3166_1: String; let english_name: String?; let native_name: String? }
        /// The regions response.
        struct Response: Decodable { let results: [Region]? }
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).map {
            TMDBRegion(code: $0.iso_3166_1, name: $0.native_name ?? $0.english_name ?? $0.iso_3166_1)
        }
    }
}
