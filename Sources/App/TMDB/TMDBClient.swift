import Foundation

enum TitleKind: String, Codable, Sendable, CaseIterable {
    case tv, movie
}

struct TMDBSearchResult: Codable, Sendable, Equatable {
    let id: Int
    let kind: TitleKind
    let name: String
    let originalName: String?
    let year: Int?
    let posterPath: String?
}

struct TMDBSeries: Sendable, Equatable {
    let id: Int
    let name: String
    let originalName: String?
    let year: Int?
    let posterPath: String?
    let status: String?
    let seasonNumbers: [Int]
    var overview: String? = nil
}

struct TMDBEpisode: Sendable, Equatable {
    let id: Int
    let season: Int
    let number: Int
    let name: String
    let airDate: String?
}

struct TMDBMovie: Sendable, Equatable {
    let id: Int
    let name: String
    let originalName: String?
    let year: Int?
    let posterPath: String?
    var overview: String? = nil
    var imdbID: String? = nil
}

enum TMDBError: Error, Equatable, CustomStringConvertible {
    case missingToken, unauthorized, notFound, rateLimited, invalidResponse
    case http(UInt)
    case network(String)

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

protocol TMDBClient: Sendable {
    /// Checks that the token is accepted (`GET /authentication`).
    func validate() async throws
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult]
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult]
    func series(id: Int) async throws -> TMDBSeries
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode]
    func movie(id: Int) async throws -> TMDBMovie
    /// IMDb id of a series (`GET /tv/{id}/external_ids`); nil when TMDB has none.
    func seriesIMDbID(id: Int) async throws -> String?
}

/// Builds a TMDB client for one user's token.
struct TMDBProvider: Sendable {
    let make: @Sendable (String) -> any TMDBClient

    init(make: @escaping @Sendable (String) -> any TMDBClient) {
        self.make = make
    }
}

/// Stand-in for users without a token: every call fails with `.missingToken`.
struct MissingTokenTMDBClient: TMDBClient {
    func validate() async throws { throw TMDBError.missingToken }
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult] { throw TMDBError.missingToken }
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult] { throw TMDBError.missingToken }
    func series(id: Int) async throws -> TMDBSeries { throw TMDBError.missingToken }
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode] { throw TMDBError.missingToken }
    func movie(id: Int) async throws -> TMDBMovie { throw TMDBError.missingToken }
    func seriesIMDbID(id: Int) async throws -> String? { throw TMDBError.missingToken }
}
