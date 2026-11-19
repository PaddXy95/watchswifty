import Fluent
import Foundation
import OpenAPIRuntime
import Vapor
import WatchSwiftyAPI

extension APIHandler {
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

    func getStandardImport(_ input: Operations.getStandardImport.Input) async throws -> Operations.getStandardImport.Output {
        .ok(.init(body: .json(try await Self.importList(try APIContext.requireUser(), request: APIContext.request()))))
    }

    func retryStandardImport(_ input: Operations.retryStandardImport.Input) async throws -> Operations.retryStandardImport.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await ImportEntryService(db: request.db).retry(userID: user.requireID())
        await request.application.importWorker.kick()
        return .ok(.init(body: .json(try await Self.importList(user, request: request))))
    }

    func acceptImportEntry(_ input: Operations.acceptImportEntry.Input) async throws -> Operations.acceptImportEntry.Output {
        let (request, entry) = try await importEntry(input.path.id)
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await StandardImporter(db: request.db, tmdb: request.tmdb, today: request.watches.today(),
                             tokenlessUser: request.catalog.tokenlessUser).record(entry, tmdbID: body.tmdbId)
        return .ok(.init(body: .json(Self.importEntry(entry))))
    }

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

    func skipImportEntry(_ input: Operations.skipImportEntry.Input) async throws -> Operations.skipImportEntry.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let entry = try await ImportEntryService(db: try APIContext.request().db).skip(userID: user.requireID(), id: id)
        return .ok(.init(body: .json(Self.importEntry(entry))))
    }

    private func importEntry(_ rawID: String) async throws -> (Request, ImportEntry) {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: rawID) else { throw APIError.notFound }
        return (request, try await ImportEntryService(db: request.db).ownEntry(userID: user.requireID(), id: id))
    }

    static func importList(_ user: User, request: Request) async throws -> Components.Schemas.ImportList {
        let entries = try await ImportEntryService(db: request.db).entries(userID: user.requireID())
        func count(_ status: ImportEntryStatus) -> Int { entries.filter { $0.entryStatus == status }.count }
        return .init(counts: .init(imported: count(.imported), review: count(.review), notFound: count(.notFound), skipped: count(.skipped),
                                   pending: count(.pending)),
                     error: entries.first { $0.entryStatus == .pending && $0.error != nil }?.error,
                     entries: entries.map(importEntry))
    }

    static func importEntry(_ entry: ImportEntry) -> Components.Schemas.ImportEntry {
        .init(id: entry.id?.uuidString ?? "", kind: entry.titleKind == .tv ? .tv : .movie, title: entry.title, year: entry.year,
              watchCount: entry.watchList.count, rating: entry.rating,
              status: Components.Schemas.ImportStatus(rawValue: entry.status) ?? .pending, tmdbId: entry.tmdbID,
              candidates: entry.candidateList.map(searchResult), missingEpisodes: entry.missingEpisodes,
              addedWatches: entry.addedWatches, error: entry.error)
    }
}
