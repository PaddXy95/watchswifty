import Fluent
import Foundation
import OpenAPIRuntime
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `POST /api/v1/imports/standard`: uploads a standard import file, which replaces the user's earlier
    /// entries (`ImportEntryService.upload`), and wakes the `ImportWorker`.
    /// - Parameter input: The generated operation input (multipart form with the file; UTF-8 or Windows-1252, at most
    ///   `StandardImportController.maxUploadBytes`).
    /// - Returns: `.ok` with the number of titles and skipped rows.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token,
    ///   `APIError.payloadTooLarge` for a too large file, `APIError.validation` without a file, for an undecodable,
    ///   unparsable or empty file or too many titles.
    func uploadStandardImport(_ input: Operations.uploadStandardImport.Input) async throws -> Operations.uploadStandardImport.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .multipartForm(form) = input.body else { throw APIError.validation("Keine Datei hochgeladen.") }
        let upload = try await uploadedFile(form, limit: StandardImportController.maxUploadBytes) { part in
            if case let .file(file) = part { return (file.payload.body, file.filename) }
            return nil
        }
        let summary = try await ImportEntryService(db: request.db)
            .upload(userID: user.requireID(), text: try uploadedText(upload.data, allowLatin: true))
        await request.application.importWorker.kick()
        return .ok(.init(body: .json(.init(titles: summary.titles, skippedRows: summary.skippedRows))))
    }

    /// Handles `GET /api/v1/imports/standard`: the user's import entries with counts per status.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the import list.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getStandardImport(_ input: Operations.getStandardImport.Input) async throws -> Operations.getStandardImport.Output {
        .ok(.init(body: .json(try await Self.importList(try APIContext.requireUser(), request: APIContext.request()))))
    }

    /// Handles `POST /api/v1/imports/standard/retry`: clears the errors of entries still waiting for TMDB
    /// (`ImportEntryService.retry`) and wakes the `ImportWorker`.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the import list.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func retryStandardImport(_ input: Operations.retryStandardImport.Input) async throws -> Operations.retryStandardImport.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await ImportEntryService(db: request.db).retry(userID: user.requireID())
        await request.application.importWorker.kick()
        return .ok(.init(body: .json(try await Self.importList(user, request: request))))
    }

    /// Handles `POST /api/v1/imports/standard/{id}/accept`: records the entry for the chosen TMDB title
    /// (`StandardImporter.record`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with `tmdbId`).
    /// - Returns: `.ok` with the updated entry.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound` /
    ///   `TrackingError.notFound` for a malformed, unknown or another user's entry, `APIError.validation` without a
    ///   body, `TMDBError` when the title is not available.
    func acceptImportEntry(_ input: Operations.acceptImportEntry.Input) async throws -> Operations.acceptImportEntry.Output {
        let (request, entry) = try await importEntry(input.path.id)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await StandardImporter(db: request.db, tmdb: request.tmdb, today: request.watches.today(),
                             tokenlessUser: request.catalog.tokenlessUser).record(entry, tmdbID: body.tmdbId)
        return .ok(.init(body: .json(Self.importEntry(entry))))
    }

    /// Handles `POST /api/v1/imports/standard/{id}/search`: searches TMDB with the user's words in the entry's kind
    /// (`StandardImporter.search`); queries shorter than two characters only return the entry.
    /// - Parameter input: The generated operation input (path `id`, JSON body with `q`).
    /// - Returns: `.ok` with the updated entry and its candidates.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound` /
    ///   `TrackingError.notFound` for a malformed, unknown or another user's entry, `APIError.validation` without a
    ///   body, `TMDBError` from the search.
    func searchImportEntry(_ input: Operations.searchImportEntry.Input) async throws -> Operations.searchImportEntry.Output {
        let (request, entry) = try await importEntry(input.path.id)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let query = body.q.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 {
            try await StandardImporter(db: request.db, tmdb: request.tmdb, today: request.watches.today(),
                             tokenlessUser: request.catalog.tokenlessUser).search(entry, query: query)
        }
        return .ok(.init(body: .json(Self.importEntry(entry))))
    }

    /// Handles `POST /api/v1/imports/standard/{id}/skip`: marks the entry as skipped (`ImportEntryService.skip`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.ok` with the updated entry.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound` /
    ///   `TrackingError.notFound` for a malformed, unknown or another user's entry.
    func skipImportEntry(_ input: Operations.skipImportEntry.Input) async throws -> Operations.skipImportEntry.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let entry = try await ImportEntryService(db: try APIContext.request().db).skip(userID: user.requireID(), id: id)
        return .ok(.init(body: .json(Self.importEntry(entry))))
    }

    /// Request and one of the signed-in user's import entries.
    /// - Parameter rawID: The entry ID from the path.
    /// - Returns: The request and the entry.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's entry.
    private func importEntry(_ rawID: String) async throws -> (Request, ImportEntry) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: rawID) else { throw APIError.notFound }
        return (request, try await ImportEntryService(db: request.db).ownEntry(userID: user.requireID(), id: id))
    }

    /// Builds the `ImportList` schema: counts per status, the first pending error and all entries.
    /// - Parameters:
    ///   - user: The signed-in user.
    ///   - request: The current request.
    /// - Returns: The schema value.
    /// - Throws: Database errors.
    static func importList(_ user: User, request: Request) async throws -> Components.Schemas.ImportList {
        let entries = try await ImportEntryService(db: request.db).entries(userID: user.requireID())
        /// Number of entries with the given status.
        func count(_ status: ImportEntryStatus) -> Int { entries.filter { $0.entryStatus == status }.count }
        return .init(counts: .init(imported: count(.imported), review: count(.review), notFound: count(.notFound), skipped: count(.skipped),
                                   pending: count(.pending)),
                     error: entries.first { $0.entryStatus == .pending && $0.error != nil }?.error,
                     entries: entries.map(importEntry))
    }

    /// Maps an import entry to the `ImportEntry` schema.
    /// - Parameter entry: The entry.
    /// - Returns: The schema value.
    static func importEntry(_ entry: ImportEntry) -> Components.Schemas.ImportEntry {
        .init(id: entry.id?.uuidString ?? "", kind: entry.titleKind == .tv ? .tv : .movie, title: entry.title, year: entry.year,
              watchCount: entry.watchList.count, rating: entry.rating,
              status: Components.Schemas.ImportStatus(rawValue: entry.status) ?? .pending, tmdbId: entry.tmdbID,
              candidates: entry.candidateList.map(searchResult), missingEpisodes: entry.missingEpisodes,
              addedWatches: entry.addedWatches, error: entry.error)
    }
}
