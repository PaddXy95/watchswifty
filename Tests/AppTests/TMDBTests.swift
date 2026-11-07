@testable import App
import NIOConcurrencyHelpers
import Testing
import VaporTesting

/// Scripted HTTP client: answers requests from a queue and records what was sent.
final class ScriptedHTTPClient: Client, @unchecked Sendable {
    let eventLoop: any EventLoop
    let responses: NIOLockedValueBox<[(HTTPStatus, HTTPHeaders, String)]>
    let sent = NIOLockedValueBox<[ClientRequest]>([])

    init(eventLoop: any EventLoop, responses: [(HTTPStatus, HTTPHeaders, String)]) {
        self.eventLoop = eventLoop
        self.responses = .init(responses)
    }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        sent.withLockedValue { $0.append(request) }
        let next = responses.withLockedValue { $0.isEmpty ? (.internalServerError, [:], "") : $0.removeFirst() }
        return eventLoop.makeSucceededFuture(ClientResponse(status: next.0, headers: next.1, body: ByteBuffer(string: next.2)))
    }
}

@Suite("TMDB")
struct TMDBTests {
    @Test func decodesTVSearch() throws {
        let json = #"{"page":1,"results":[{"id":1420,"name":"The Mentalist","original_name":"The Mentalist","first_air_date":"2008-09-23","poster_path":"/p.jpg"},{"id":2,"name":"X","original_name":"X","first_air_date":"","poster_path":null}]}"#
        let results = try LiveTMDBClient.decodeSearch(Data(json.utf8), kind: .tv)
        #expect(results == [
            TMDBSearchResult(id: 1420, kind: .tv, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: "/p.jpg"),
            TMDBSearchResult(id: 2, kind: .tv, name: "X", originalName: "X", year: nil, posterPath: nil),
        ])
    }

    @Test func decodesMovieSearch() throws {
        let json = #"{"results":[{"id":603,"title":"Matrix","original_title":"The Matrix","release_date":"1999-03-30","poster_path":"/m.jpg"}]}"#
        let results = try LiveTMDBClient.decodeSearch(Data(json.utf8), kind: .movie)
        #expect(results == [TMDBSearchResult(id: 603, kind: .movie, name: "Matrix", originalName: "The Matrix", year: 1999, posterPath: "/m.jpg")])
    }

    @Test func multiSkipsPeople() throws {
        let json = #"{"results":[{"id":1,"media_type":"tv","name":"Serie","first_air_date":"2010-01-01"},{"id":2,"media_type":"person","name":"Jemand"},{"id":3,"media_type":"movie","title":"Film","release_date":"2011-05-05"}]}"#
        let results = try LiveTMDBClient.decodeMulti(Data(json.utf8))
        #expect(results.map(\.id) == [1, 3])
        #expect(results.map(\.kind) == [.tv, .movie])
        #expect(results[1].name == "Film")
    }

    @Test func decodesSeasonEpisodesWithEmptyAirDate() throws {
        let json = #"{"episodes":[{"id":11,"episode_number":1,"season_number":1,"name":"Pilot","air_date":"2008-09-23"},{"id":12,"episode_number":2,"season_number":1,"name":"Rote Haare","air_date":""},{"id":13,"episode_number":3,"season_number":1,"name":"Drei","air_date":null}]}"#
        let episodes = try LiveTMDBClient.decodeSeason(Data(json.utf8))
        #expect(episodes == [
            TMDBEpisode(id: 11, season: 1, number: 1, name: "Pilot", airDate: "2008-09-23"),
            TMDBEpisode(id: 12, season: 1, number: 2, name: "Rote Haare", airDate: nil),
            TMDBEpisode(id: 13, season: 1, number: 3, name: "Drei", airDate: nil),
        ])
    }

    @Test func decodesSeriesAndMovie() throws {
        let series = try LiveTMDBClient.decodeSeries(Data(#"{"id":1420,"name":"The Mentalist","original_name":"The Mentalist","first_air_date":"2008-09-23","poster_path":"/p.jpg","status":"Ended","seasons":[{"season_number":0},{"season_number":1}]}"#.utf8))
        #expect(series == TMDBSeries(id: 1420, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: "/p.jpg", status: "Ended", seasonNumbers: [0, 1]))
        let movie = try LiveTMDBClient.decodeMovie(Data(#"{"id":603,"title":"Matrix","original_title":"The Matrix","release_date":"1999-03-30","poster_path":"/m.jpg"}"#.utf8))
        #expect(movie == TMDBMovie(id: 603, name: "Matrix", originalName: "The Matrix", year: 1999, posterPath: "/m.jpg"))
    }

    @Test func urlCarriesLanguageAndEncodesQuery() {
        let uri = LiveTMDBClient.url(path: "search/tv", query: ["query": "Pokémon", "include_adult": "false"], language: "de-DE")
        #expect(uri.string.hasPrefix("https://api.themoviedb.org/3/search/tv?"))
        #expect(uri.string.contains("language=de-DE"))
        #expect(uri.string.contains("query=Pok%C3%A9mon"))
        #expect(uri.string.contains("include_adult=false"))
    }

    @Test func retryDelayRules() {
        #expect(LiveTMDBClient.retryDelay(status: 429, retryAfter: "3", attempt: 1) == .seconds(3))
        #expect(LiveTMDBClient.retryDelay(status: 429, retryAfter: nil, attempt: 1) == .seconds(2))
        #expect(LiveTMDBClient.retryDelay(status: 429, retryAfter: "3", attempt: 4) == nil)
        #expect(LiveTMDBClient.retryDelay(status: 500, retryAfter: nil, attempt: 1) == nil)
    }

    @Test func sendsBearerTokenAndRetriesAfter429() async throws {
        let http = ScriptedHTTPClient(eventLoop: MultiThreadedEventLoopGroup.singleton.next(), responses: [
            (.tooManyRequests, ["Retry-After": "0"], ""),
            (.ok, [:], #"{"results":[]}"#),
        ])
        let client = LiveTMDBClient(client: http, token: "secret", language: "de-DE", limiter: RateLimiter(minInterval: .zero))
        let results = try await client.search("Dark", kind: .tv)
        #expect(results.isEmpty)
        let sent = http.sent.withLockedValue { $0 }
        #expect(sent.count == 2)
        #expect(sent.first?.headers.first(name: .authorization) == "Bearer secret")
    }

    @Test func mapsUnauthorizedAndNotFound() async throws {
        let http = ScriptedHTTPClient(eventLoop: MultiThreadedEventLoopGroup.singleton.next(), responses: [
            (.unauthorized, [:], ""), (.notFound, [:], ""),
        ])
        let client = LiveTMDBClient(client: http, token: "bad", language: "de-DE", limiter: RateLimiter(minInterval: .zero))
        await #expect(throws: TMDBError.unauthorized) { try await client.series(id: 1) }
        await #expect(throws: TMDBError.notFound) { try await client.movie(id: 2) }
    }
}
