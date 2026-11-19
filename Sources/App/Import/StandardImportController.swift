import Fluent
import Vapor

/// Web front door of the standard import (`/import/standard`, spec `2026-11-19-standard-import-design.md` §6).
struct StandardImportController {
    struct UploadInput: Content { var file: File }
    struct AcceptInput: Content { var tmdbID: Int }
    struct SearchInput: Content { var q: String }

    static let maxUploadBytes = 5 * 1024 * 1024

    func register(on protected: any RoutesBuilder) {
        protected.get("import", "standard", use: page)
        protected.on(.POST, "import", "standard", body: .collect(maxSize: "6mb"), use: upload)
        protected.get("import", "standard", "status", use: status)
        protected.post("import", "standard", "retry", use: retry)
        protected.post("import", "standard", ":entryID", "accept", use: accept)
        protected.post("import", "standard", ":entryID", "search", use: search)
        protected.post("import", "standard", ":entryID", "skip", use: skip)
    }

    func page(req: Request) async throws -> HTMLResponse {
        try await render(req)
    }

    func upload(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(UploadInput.self)
        guard input.file.data.readableBytes <= Self.maxUploadBytes else { throw Abort(.payloadTooLarge) }
        let data = Data(input.file.data.readableBytesView)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            return try await render(req, status: .unprocessableEntity, error: "Die Datei ließ sich nicht lesen.")
        }
        let summary: ImportUploadSummary
        do {
            summary = try await ImportEntryService(db: req.db).upload(userID: try req.userID, text: text)
        } catch let error as APIError {
            return try await render(req, status: .unprocessableEntity, error: error.message)
        }
        await req.application.importWorker.kick()
        return try await render(req, notice: Self.uploadNotice(summary))
    }

    static func uploadNotice(_ summary: ImportUploadSummary) -> String {
        var text = "\(summary.titles) Titel übernommen – die Zuordnung zu TMDB läuft im Hintergrund."
        if summary.skippedRows > 0 {
            text += " \(summary.skippedRows == 1 ? "1 Zeile" : "\(summary.skippedRows) Zeilen") übersprungen "
                + "(unbekannter Typ, fehlender Titel oder fehlende Staffel/Episode)."
        }
        return text
    }

    /// Progress fragment for polling; when nothing is pending any more, the page reloads to show the results.
    func status(req: Request) async throws -> Response {
        let entries = try await ImportEntryService(db: req.db).entries(userID: try req.userID)
        let response = try await HTMLResponse(ImportStatusBox(entries: entries)).encodeResponse(for: req)
        if (try? req.query.get(String.self, at: "polling")) == "1", !entries.contains(where: { $0.entryStatus == .pending }) {
            response.headers.replaceOrAdd(name: "HX-Refresh", value: "true")
        }
        return response
    }

    func retry(req: Request) async throws -> HTMLResponse {
        let service = ImportEntryService(db: req.db)
        try await service.retry(userID: try req.userID)
        await req.application.importWorker.kick()
        return HTMLResponse(ImportStatusBox(entries: try await service.entries(userID: try req.userID)))
    }

    func accept(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        try await importer(req).record(entry, tmdbID: try req.content.decode(AcceptInput.self).tmdbID)
        return HTMLResponse(ImportEntryCard(entry: entry))
    }

    func search(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        let query = try req.content.decode(SearchInput.self).q.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 { try await importer(req).search(entry, query: query) }
        return HTMLResponse(ImportEntryCard(entry: entry))
    }

    func skip(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return HTMLResponse(ImportEntryCard(entry: try await ImportEntryService(db: req.db).skip(userID: try req.userID, id: id)))
    }

    private func importer(_ req: Request) -> StandardImporter {
        StandardImporter(db: req.db, tmdb: req.tmdb, today: req.application.appConfig.today(), tokenlessUser: req.catalog.tokenlessUser)
    }

    private func ownEntry(_ req: Request) async throws -> ImportEntry {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return try await ImportEntryService(db: req.db).ownEntry(userID: try req.userID, id: id)
    }

    private func render(_ req: Request, status: HTTPStatus = .ok, error: String? = nil, notice: String? = nil) async throws -> HTMLResponse {
        let entries = try await ImportEntryService(db: req.db).entries(userID: try req.userID)
        return HTMLResponse(status: status, StandardImportPage(nav: try req.nav(.importing), entries: entries, error: error, notice: notice))
    }
}
