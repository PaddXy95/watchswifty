import Fluent
import Vapor

/// Web front door of the standard import (`/import/standard`, spec `2026-11-19-standard-import-design.md` §6).
struct StandardImportController {
    /// Multipart form with the uploaded CSV file.
    struct UploadInput: Content { var file: File }
    /// Form with the TMDB ID chosen for an entry.
    struct AcceptInput: Content { var tmdbID: Int }
    /// Form with the user's own search words for an entry.
    struct SearchInput: Content { var q: String }

    /// Largest accepted file (5 MB); the upload route collects request bodies up to 6 MB.
    static let maxUploadBytes = 5 * 1024 * 1024

    /// Registers the standard import routes on the authenticated route group.
    /// - Parameter protected: The route group requiring a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("import", "standard", use: page)
        protected.on(.POST, "import", "standard", body: .collect(maxSize: "6mb"), use: upload)
        protected.get("import", "standard", "status", use: status)
        protected.post("import", "standard", "retry", use: retry)
        protected.post("import", "standard", ":entryID", "accept", use: accept)
        protected.post("import", "standard", ":entryID", "search", use: search)
        protected.post("import", "standard", ":entryID", "skip", use: skip)
    }

    /// `GET /import/standard`: renders the standard import page with the user's entries.
    /// - Parameter req: The request.
    /// - Returns: The standard import page.
    /// - Throws: A database error.
    func page(req: Request) async throws -> HTMLResponse {
        try await render(req)
    }

    /// `POST /import/standard`: parses an upload (UTF-8, else Windows-1252), replaces the user's entries, kicks the
    /// import worker and renders the page with a notice; an unreadable or invalid file renders an error with status 422.
    /// - Parameter req: The request with the multipart `file`.
    /// - Returns: The standard import page.
    /// - Throws: `Abort(.payloadTooLarge)` above `maxUploadBytes`, a decoding or database error.
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

    /// The German notice after an upload: titles taken over and, if any, skipped lines.
    /// - Parameter summary: The upload summary.
    /// - Returns: The notice text.
    static func uploadNotice(_ summary: ImportUploadSummary) -> String {
        var text = "\(summary.titles) Titel übernommen – die Zuordnung zu TMDB läuft im Hintergrund."
        if summary.skippedRows > 0 {
            text += " \(summary.skippedRows == 1 ? "1 Zeile" : "\(summary.skippedRows) Zeilen") übersprungen "
                + "(unbekannter Typ, fehlender Titel oder fehlende Staffel/Episode)."
        }
        return text
    }

    /// Progress fragment for polling; when nothing is pending any more, the page reloads to show the results.
    ///
    /// `GET /import/standard/status`.
    /// - Parameter req: The request; `polling=1` marks a request from the polling element and enables `HX-Refresh`.
    /// - Returns: The status box fragment.
    /// - Throws: A database error.
    func status(req: Request) async throws -> Response {
        let entries = try await ImportEntryService(db: req.db).entries(userID: try req.userID)
        let response = try await HTMLResponse(ImportStatusBox(entries: entries)).encodeResponse(for: req)
        if (try? req.query.get(String.self, at: "polling")) == "1", !entries.contains(where: { $0.entryStatus == .pending }) {
            response.headers.replaceOrAdd(name: "HX-Refresh", value: "true")
        }
        return response
    }

    /// `POST /import/standard/retry`: clears the errors of pending entries, kicks the import worker and returns the status
    /// box.
    /// - Parameter req: The request.
    /// - Returns: The status box fragment.
    /// - Throws: A database error.
    func retry(req: Request) async throws -> HTMLResponse {
        let service = ImportEntryService(db: req.db)
        try await service.retry(userID: try req.userID)
        await req.application.importWorker.kick()
        return HTMLResponse(ImportStatusBox(entries: try await service.entries(userID: try req.userID)))
    }

    /// `POST /import/standard/:entryID/accept`: records the entry for the chosen TMDB title.
    /// - Parameter req: The request with an `AcceptInput` form.
    /// - Returns: The updated entry card.
    /// - Throws: `TrackingError.notFound` for a foreign entry, `Abort(.notFound)` for a malformed ID, `TMDBError`.
    func accept(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        try await importer(req).record(entry, tmdbID: try req.content.decode(AcceptInput.self).tmdbID)
        return HTMLResponse(ImportEntryCard(entry: entry))
    }

    /// `POST /import/standard/:entryID/search`: searches TMDB with the user's words (at least 2 characters) and shows the
    /// hits as candidates.
    /// - Parameter req: The request with a `SearchInput` form.
    /// - Returns: The updated entry card.
    /// - Throws: `TrackingError.notFound` for a foreign entry, `Abort(.notFound)` for a malformed ID, `TMDBError`.
    func search(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        let query = try req.content.decode(SearchInput.self).q.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 { try await importer(req).search(entry, query: query) }
        return HTMLResponse(ImportEntryCard(entry: entry))
    }

    /// `POST /import/standard/:entryID/skip`: marks the entry as skipped.
    /// - Parameter req: The request.
    /// - Returns: The updated entry card.
    /// - Throws: `TrackingError.notFound` for a foreign entry, `Abort(.notFound)` for a malformed ID.
    func skip(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return HTMLResponse(ImportEntryCard(entry: try await ImportEntryService(db: req.db).skip(userID: try req.userID, id: id)))
    }

    /// An importer with the logged-in user's TMDB client.
    /// - Parameter req: The request.
    /// - Returns: The importer, restricted like the catalog when the user has no TMDB token.
    private func importer(_ req: Request) -> StandardImporter {
        StandardImporter(db: req.db, tmdb: req.tmdb, today: req.application.appConfig.today(), tokenlessUser: req.catalog.tokenlessUser)
    }

    /// Loads the `entryID` path parameter's entry through the logged-in user.
    /// - Parameter req: The request.
    /// - Returns: The user's entry.
    /// - Throws: `Abort(.notFound)` for a malformed ID, `TrackingError.notFound` for a foreign or unknown entry.
    private func ownEntry(_ req: Request) async throws -> ImportEntry {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return try await ImportEntryService(db: req.db).ownEntry(userID: try req.userID, id: id)
    }

    /// Renders the standard import page with the user's entries.
    /// - Parameters:
    ///   - req: The request.
    ///   - status: The HTTP status.
    ///   - error: An error message to show, if any.
    ///   - notice: A notice to show, if any.
    /// - Returns: The standard import page.
    /// - Throws: A database error.
    private func render(_ req: Request, status: HTTPStatus = .ok, error: String? = nil, notice: String? = nil) async throws -> HTMLResponse {
        let entries = try await ImportEntryService(db: req.db).entries(userID: try req.userID)
        return HTMLResponse(status: status, StandardImportPage(nav: try req.nav(.importing), entries: entries, error: error, notice: notice))
    }
}
