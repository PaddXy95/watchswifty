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

    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func decodeSearch(_ data: Data, kind: TitleKind) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { $0.result(kind: kind) }
    }

    static func decodeMulti(_ data: Data) throws -> [TMDBSearchResult] {
        try JSONDecoder().decode(ResultList.self, from: data).results.compactMap { item in
            guard let raw = item.media_type, let kind = TitleKind(rawValue: raw) else { return nil }
            return item.result(kind: kind)
        }
    }

    static func decodeSeries(_ data: Data) throws -> TMDBSeries {
        struct Season: Decodable { let season_number: Int }
        struct Series: Decodable {
            let id: Int; let name: String; let original_name: String?; let first_air_date: String?
            let poster_path: String?; let status: String?; let seasons: [Season]?; let overview: String?
        }
        let s = try JSONDecoder().decode(Series.self, from: data)
        return TMDBSeries(id: s.id, name: s.name, originalName: s.original_name, year: year(s.first_air_date),
                          posterPath: s.poster_path, status: s.status, seasonNumbers: (s.seasons ?? []).map(\.season_number),
                          overview: blankToNil(s.overview))
    }

    static func decodeSeason(_ data: Data) throws -> [TMDBEpisode] {
        struct Episode: Decodable {
            let id: Int; let episode_number: Int; let season_number: Int; let name: String?; let air_date: String?; let overview: String?
        }
        struct Season: Decodable { let episodes: [Episode]? }
        return try (JSONDecoder().decode(Season.self, from: data).episodes ?? []).map {
            TMDBEpisode(id: $0.id, season: $0.season_number, number: $0.episode_number, name: $0.name ?? "", airDate: blankToNil($0.air_date),
                        overview: blankToNil($0.overview))
        }
    }

    static func decodeExternalIDs(_ data: Data) throws -> String? {
        struct IDs: Decodable { let imdb_id: String? }
        return blankToNil(try JSONDecoder().decode(IDs.self, from: data).imdb_id)
    }

    static func decodeMovie(_ data: Data) throws -> TMDBMovie {
        struct Movie: Decodable {
            let id: Int; let title: String; let original_title: String?; let release_date: String?; let poster_path: String?
            let overview: String?; let imdb_id: String?
        }
        let m = try JSONDecoder().decode(Movie.self, from: data)
        return TMDBMovie(id: m.id, name: m.title, originalName: m.original_title, year: year(m.release_date), posterPath: m.poster_path,
                         overview: blankToNil(m.overview), imdbID: blankToNil(m.imdb_id))
    }
}
