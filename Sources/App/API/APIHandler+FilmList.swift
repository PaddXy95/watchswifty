import Fluent
import Foundation
import OpenAPIRuntime
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func uploadFilmList(_ input: Operations.uploadFilmList.Input) async throws -> Operations.uploadFilmList.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .multipartForm(form) = input.body else { throw APIError.validation("Keine Datei hochgeladen.") }
        let upload = try await uploadedFile(form, limit: 2 * 1024 * 1024) { part in
            if case let .file(file) = part { return (file.payload.body, file.filename) }
            return nil
        }
        let count = try await FilmListService(db: request.db).upload(userID: user.requireID(), text: try uploadedText(upload.data, allowLatin: true))
        await request.application.filmListWorker.kick()
        return .ok(.init(body: .json(.init(films: count))))
    }

    func getFilmList(_ input: Operations.getFilmList.Input) async throws -> Operations.getFilmList.Output {
        .ok(.init(body: .json(try await Self.filmList(try APIContext.requireUser(), request: APIContext.request()))))
    }

    func retryFilmList(_ input: Operations.retryFilmList.Input) async throws -> Operations.retryFilmList.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await FilmListService(db: request.db).retry(userID: user.requireID())
        await request.application.filmListWorker.kick()
        return .ok(.init(body: .json(try await Self.filmList(user, request: request))))
    }

    func acceptFilm(_ input: Operations.acceptFilm.Input) async throws -> Operations.acceptFilm.Output {
        let (request, entry) = try await filmEntry(input.path.id)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await FilmListImporter(db: request.db, tmdb: request.tmdb, today: request.watches.today()).record(entry, tmdbID: body.tmdbId)
        return .ok(.init(body: .json(Self.filmEntry(entry))))
    }

    func searchFilm(_ input: Operations.searchFilm.Input) async throws -> Operations.searchFilm.Output {
        let (request, entry) = try await filmEntry(input.path.id)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let query = body.q.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 {
            try await FilmListImporter(db: request.db, tmdb: request.tmdb, today: request.watches.today()).search(entry, query: query)
        }
        return .ok(.init(body: .json(Self.filmEntry(entry))))
    }

    func skipFilm(_ input: Operations.skipFilm.Input) async throws -> Operations.skipFilm.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let entry = try await FilmListService(db: try APIContext.request().db).skip(userID: user.requireID(), id: id)
        return .ok(.init(body: .json(Self.filmEntry(entry))))
    }

    private func filmEntry(_ rawID: String) async throws -> (Request, FilmListEntry) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: rawID) else { throw APIError.notFound }
        return (request, try await FilmListService(db: request.db).ownEntry(userID: user.requireID(), id: id))
    }

    static func filmList(_ user: User, request: Request) async throws -> Components.Schemas.FilmList {
        let entries = try await FilmListService(db: request.db).entries(userID: user.requireID())
        func count(_ status: FilmListStatus) -> Int { entries.filter { $0.filmStatus == status }.count }
        return .init(counts: .init(imported: count(.imported), review: count(.review), notFound: count(.notFound), skipped: count(.skipped),
                                   pending: count(.pending)),
                     error: entries.first { $0.filmStatus == .pending && $0.error != nil }?.error,
                     entries: entries.map(filmEntry))
    }

    static func filmEntry(_ entry: FilmListEntry) -> Components.Schemas.FilmEntry {
        .init(id: entry.id?.uuidString ?? "", title: entry.title, year: entry.year, watchCount: entry.watchList.count, rating: entry.rating,
              status: Components.Schemas.FilmStatus(rawValue: entry.status) ?? .pending, tmdbId: entry.tmdbID,
              candidates: entry.candidateList.map(searchResult), error: entry.error)
    }
}
