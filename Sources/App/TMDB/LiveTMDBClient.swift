import Foundation
import NIOCore
import Vapor

struct LiveTMDBClient: TMDBClient {
    static let baseURL = "https://api.themoviedb.org/3"

    let client: any Client
    let token: String
    let language: String
    let limiter: RateLimiter

    // MARK: TMDBClient

    func validate() async throws {
        _ = try await get("authentication", [:])
    }

    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult] {
        let data = try await get("search/\(kind.rawValue)", ["query": query, "include_adult": "false"])
        return try Self.decoding { try Self.decodeSearch(data, kind: kind) }
    }

    func searchMulti(_ query: String) async throws -> [TMDBSearchResult] {
        let data = try await get("search/multi", ["query": query, "include_adult": "false"])
        return try Self.decoding { try Self.decodeMulti(data) }
    }

    func series(id: Int) async throws -> TMDBSeries {
        let data = try await get("tv/\(id)", [:])
        return try Self.decoding { try Self.decodeSeries(data) }
    }

    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode] {
        let data = try await get("tv/\(seriesID)/season/\(number)", [:])
        return try Self.decoding { try Self.decodeSeason(data) }
    }

    func movie(id: Int) async throws -> TMDBMovie {
        let data = try await get("movie/\(id)", [:])
        return try Self.decoding { try Self.decodeMovie(data) }
    }

    /// Maps malformed bodies (proxies, captive portals, API changes) to `.invalidResponse`.
    static func decoding<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch is DecodingError { throw TMDBError.invalidResponse }
    }

    func seriesIMDbID(id: Int) async throws -> String? {
        let data = try await get("tv/\(id)/external_ids", [:])
        return try Self.decoding { try Self.decodeExternalIDs(data) }
    }

    func find(imdbID: String) async throws -> TMDBFindResult {
        let data = try await get("find/\(imdbID)", ["external_source": "imdb_id"])
        return try Self.decoding { try Self.decodeFind(data) }
    }

    func watchProviders(kind: TitleKind, id: Int) async throws -> TMDBWatchProviders {
        let data = try await get("\(kind.rawValue)/\(id)/watch/providers", [:])
        return try Self.decoding { try Self.decodeWatchProviders(data) }
    }

    func providers(kind: TitleKind, region: String) async throws -> [TMDBProviderInfo] {
        let data = try await get("watch/providers/\(kind.rawValue)", ["watch_region": region])
        return try Self.decoding { try Self.decodeProviderList(data) }
    }

    func providerRegions() async throws -> [TMDBRegion] {
        let data = try await get("watch/providers/regions", [:])
        return try Self.decoding { try Self.decodeRegions(data) }
    }

    // MARK: HTTP

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
    static func retryDelay(status: UInt, retryAfter: String?, attempt: Int) -> Duration? {
        guard status == 429, attempt <= 3 else { return nil }
        return .seconds(retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 2)
    }

    // MARK: Decoding

    private struct ResultList: Decodable { let results: [Item] }
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

    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func decodeSearch(_ data: Data, kind: TitleKind) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { $0.result(kind: kind) }
    }

    static func decodeFind(_ data: Data) throws -> TMDBFindResult {
        struct EpisodeRef: Decodable { let show_id: Int? }
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

    static func decodeMulti(_ data: Data) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { item in
            guard let raw = item.media_type, let kind = TitleKind(rawValue: raw) else { return nil }
            return item.result(kind: kind)
        }
    }

    private struct GenreRef: Decodable { let id: Int }

    static func decodeSeries(_ data: Data) throws -> TMDBSeries {
        struct Season: Decodable { let season_number: Int }
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

    static func decodeSeason(_ data: Data) throws -> [TMDBEpisode] {
        struct Episode: Decodable {
            let id: Int; let episode_number: Int; let season_number: Int; let name: String?; let air_date: String?; let overview: String?
            let runtime: Int?
        }
        struct Season: Decodable { let episodes: [Episode]? }
        return try (JSONDecoder().decode(Season.self, from: data).episodes ?? []).map {
            TMDBEpisode(id: $0.id, season: $0.season_number, number: $0.episode_number, name: $0.name ?? "", airDate: blankToNil($0.air_date),
                        overview: blankToNil($0.overview), runtime: positive($0.runtime))
        }
    }

    static func decodeExternalIDs(_ data: Data) throws -> String? {
        struct IDs: Decodable { let imdb_id: String? }
        return blankToNil(try JSONDecoder().decode(IDs.self, from: data).imdb_id)
    }

    static func decodeMovie(_ data: Data) throws -> TMDBMovie {
        struct Movie: Decodable {
            let id: Int; let title: String; let original_title: String?; let release_date: String?; let poster_path: String?
            let overview: String?; let imdb_id: String?; let runtime: Int?; let genres: [GenreRef]?
        }
        let m = try JSONDecoder().decode(Movie.self, from: data)
        return TMDBMovie(id: m.id, name: m.title, originalName: m.original_title, year: year(m.release_date), posterPath: m.poster_path,
                         overview: blankToNil(m.overview), imdbID: blankToNil(m.imdb_id), runtime: positive(m.runtime),
                         genreIDs: (m.genres ?? []).map(\.id))
    }

    private struct ProviderRef: Decodable {
        let provider_id: Int; let provider_name: String; let logo_path: String?; let display_priority: Int?
    }

    static func decodeWatchProviders(_ data: Data) throws -> TMDBWatchProviders {
        struct Region: Decodable {
            let link: String?
            let flatrate: [ProviderRef]?; let free: [ProviderRef]?; let ads: [ProviderRef]?
            let rent: [ProviderRef]?; let buy: [ProviderRef]?
        }
        struct Response: Decodable { let results: [String: Region]? }
        var result = TMDBWatchProviders()
        for (code, region) in try JSONDecoder().decode(Response.self, from: data).results ?? [:] {
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

    static func decodeProviderList(_ data: Data) throws -> [TMDBProviderInfo] {
        struct Response: Decodable { let results: [ProviderRef]? }
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).map {
            TMDBProviderInfo(providerID: $0.provider_id, name: $0.provider_name, logoPath: $0.logo_path,
                             displayPriority: $0.display_priority ?? Int.max)
        }
    }

    static func decodeRegions(_ data: Data) throws -> [TMDBRegion] {
        struct Region: Decodable { let iso_3166_1: String; let english_name: String?; let native_name: String? }
        struct Response: Decodable { let results: [Region]? }
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).map {
            TMDBRegion(code: $0.iso_3166_1, name: $0.native_name ?? $0.english_name ?? $0.iso_3166_1)
        }
    }
}
