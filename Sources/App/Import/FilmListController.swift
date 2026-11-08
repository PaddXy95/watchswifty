import Fluent
import Vapor

struct FilmListController {
    struct UploadInput: Content { var file: File }
    struct AcceptInput: Content { var tmdbID: Int }
    struct SearchInput: Content { var q: String }

    static let notFilmListMessage = FilmListService.notFilmListMessage

    func register(on protected: any RoutesBuilder) {
        protected.get("import", "films", use: page)
        protected.on(.POST, "import", "films", body: .collect(maxSize: "2mb"), use: upload)
        protected.get("import", "films", "status", use: status)
        protected.post("import", "films", "retry", use: retry)
        protected.post("import", "films", ":entryID", "accept", use: accept)
        protected.post("import", "films", ":entryID", "search", use: search)
        protected.post("import", "films", ":entryID", "skip", use: skip)
    }

    func page(req: Request) async throws -> HTMLResponse {
        try await render(req)
    }

    func upload(req: Request) async throws -> HTMLResponse {
        let input = try req.content.decode(UploadInput.self)
        guard input.file.data.readableBytes <= 2 * 1024 * 1024 else { throw Abort(.payloadTooLarge) }
        let data = Data(input.file.data.readableBytesView)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            return try await render(req, status: .unprocessableEntity, error: "Die Datei ließ sich nicht lesen.")
        }
        let count: Int
        do {
            count = try await FilmListService(db: req.db).upload(userID: try req.userID, text: text)
        } catch let error as APIError {
            return try await render(req, status: .unprocessableEntity, error: error.message)
        }
        await req.application.filmListWorker.kick()
        return try await render(req, notice: "\(count) Filme übernommen – die Zuordnung zu TMDB läuft im Hintergrund.")
    }

    /// Progress fragment for polling; when nothing is pending any more, the page reloads to show the results.
    func status(req: Request) async throws -> Response {
        let entries = try await FilmListService(db: req.db).entries(userID: try req.userID)
        let response = try await HTMLResponse(FilmListStatusBox(entries: entries)).encodeResponse(for: req)
        if (try? req.query.get(String.self, at: "polling")) == "1", !entries.contains(where: { $0.filmStatus == .pending }) {
            response.headers.replaceOrAdd(name: "HX-Refresh", value: "true")
        }
        return response
    }

    func retry(req: Request) async throws -> HTMLResponse {
        try await FilmListService(db: req.db).retry(userID: try req.userID)
        await req.application.filmListWorker.kick()
        return HTMLResponse(FilmListStatusBox(entries: try await FilmListService(db: req.db).entries(userID: try req.userID)))
    }

    func accept(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        try await importer(req).record(entry, tmdbID: try req.content.decode(AcceptInput.self).tmdbID)
        return HTMLResponse(FilmEntryCard(entry: entry))
    }

    func search(req: Request) async throws -> HTMLResponse {
        let entry = try await ownEntry(req)
        let query = try req.content.decode(SearchInput.self).q.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 { try await importer(req).search(entry, query: query) }
        return HTMLResponse(FilmEntryCard(entry: entry))
    }

    func skip(req: Request) async throws -> HTMLResponse {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return HTMLResponse(FilmEntryCard(entry: try await FilmListService(db: req.db).skip(userID: try req.userID, id: id)))
    }

    private func importer(_ req: Request) -> FilmListImporter {
        FilmListImporter(db: req.db, tmdb: req.tmdb, today: req.application.appConfig.today())
    }

    private func ownEntry(_ req: Request) async throws -> FilmListEntry {
        guard let id = req.parameters.get("entryID", as: UUID.self) else { throw Abort(.notFound) }
        return try await FilmListService(db: req.db).ownEntry(userID: try req.userID, id: id)
    }

    private func render(_ req: Request, status: HTTPStatus = .ok, error: String? = nil, notice: String? = nil) async throws -> HTMLResponse {
        let entries = try await FilmListService(db: req.db).entries(userID: try req.userID)
        return HTMLResponse(status: status, FilmListPage(nav: try req.nav(.importing), entries: entries, error: error, notice: notice))
    }
}
