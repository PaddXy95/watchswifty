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
}

enum TMDBError: Error, Equatable, CustomStringConvertible {
    case unauthorized, notFound, rateLimited
    case http(UInt)
    case network(String)

    var description: String {
        switch self {
        case .unauthorized: "Token ungültig (HTTP 401)"
        case .notFound: "nicht gefunden (HTTP 404)"
        case .rateLimited: "Anfragelimit erreicht (HTTP 429)"
        case .http(let code): "HTTP \(code)"
        case .network(let message): message
        }
    }
}

protocol TMDBClient: Sendable {
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult]
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult]
    func series(id: Int) async throws -> TMDBSeries
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode]
    func movie(id: Int) async throws -> TMDBMovie
}
