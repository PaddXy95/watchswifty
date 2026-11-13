@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct GenresBody: Codable { let name: String?; let genres: [String] }

@Suite("GenreView")
struct GenreViewTests {
    /// "Dunkel" (series, Drama), "Lachen" (movie, Komödie), "Unbekannt" (movie, genres not fetched yet) – all watched by pat.
    func withLibrary(_ body: (Application, User) async throws -> Void) async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let ws = WatchService(db: app.db)
            let dark = try await seedSeries(app, tmdbID: 1, name: "Dunkel", seasons: [1: 1], genres: "drama,crime")
            let laugh = try await seedMovie(app, tmdbID: 2, name: "Lachen", runtime: 90, genres: "comedy")
            let unknown = try await seedMovie(app, tmdbID: 3, name: "Unbekannt", genres: nil)
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, dark, 1, 1).requireID(), day: "2026-11-01", service: nil)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: laugh.requireID(), day: "2026-11-02", service: nil)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: unknown.requireID(), day: "2026-11-03", service: nil)
            try await body(app, user)
        }
    }

    func page(_ app: Application, _ path: String) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.testing().test(.GET, path, headers: try await login(app, "pat")) { res async in
            result = (res.status, res.body.string)
        }
        return result
    }

    @Test func detailPagesShowGenres() async throws {
        try await withLibrary { app, _ in
            let series = try await page(app, "/tv/1").1
            let movie = try await page(app, "/movie/2").1
            #expect(series.contains("Drama · Krimi"))
            #expect(movie.contains("Komödie"))
        }
    }

    @Test func libraryOffersOnlyOwnGenres() async throws {
        try await withLibrary { app, _ in
            let body = try await page(app, "/library").1
            #expect(body.contains("Dunkel") && body.contains("Lachen") && body.contains("Unbekannt"))
            #expect(body.contains(#"<option value="drama">Drama</option>"#))
            #expect(body.contains(#"<option value="comedy">Komödie</option>"#))
            #expect(!body.contains(#"<option value="action">"#))
        }
    }

    @Test func libraryFiltersByGenre() async throws {
        try await withLibrary { app, _ in
            let body = try await page(app, "/library?genre=drama").1
            #expect(body.contains("Dunkel"))
            #expect(!body.contains("Lachen"))
            #expect(!body.contains("Unbekannt"))
            #expect(body.contains(#"<option value="drama" selected>"#))
            #expect(body.contains("/library?filter=movie&amp;sort=recent&amp;genre=drama"))
        }
    }

    @Test func unknownGenreIsIgnored() async throws {
        try await withLibrary { app, _ in
            let (status, body) = try await page(app, "/library?genre=quatsch")
            #expect(status == .ok)
            #expect(body.contains("Dunkel") && body.contains("Lachen") && body.contains("Unbekannt"))
        }
    }

    @Test func apiLibraryFiltersAndListsGenres() async throws {
        try await withLibrary { app, user in
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/library?genre=drama", headers: .bearer(token)) { res async throws in
                #expect(res.status == .ok)
                let entries = try res.content.decode([GenresBody].self)
                #expect(entries.map(\.name) == ["Dunkel"])
                #expect(entries.first?.genres == ["drama", "crime"])
            }
            try await app.testing().test(.GET, "/api/v1/library", headers: .bearer(token)) { res async throws in
                let entries = try res.content.decode([GenresBody].self)
                #expect(entries.first { $0.name == "Unbekannt" }?.genres == [])
            }
            try await app.testing().test(.GET, "/api/v1/library?genre=quatsch", headers: .bearer(token)) { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test func apiDetailsCarryGenres() async throws {
        try await withLibrary { app, user in
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/tv/1", headers: .bearer(token)) { res async throws in
                let detail = try res.content.decode(GenresBody.self)
                #expect(detail.genres == ["drama", "crime"])
            }
            try await app.testing().test(.GET, "/api/v1/movies/2", headers: .bearer(token)) { res async throws in
                let detail = try res.content.decode(GenresBody.self)
                #expect(detail.genres == ["comedy"])
            }
        }
    }
}
