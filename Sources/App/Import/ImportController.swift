import Fluent
import Vapor

struct ImportController {
    struct UploadInput: Content { var file: File }
    struct DecisionInput: Content { var kind: String; var tmdbID: Int }
    struct AssignInput: Content { var episodeID: UUID }

    static let notNetflixMessage = "Das ist keine Netflix-Wiedergabeaktivität (erwartet wird die Kopfzeile „Title,Date“)."
    static let unmatchedLimit = ImportStateService.unmatchedLimit

    func register(on protected: any RoutesBuilder) {
        protected.get("import", use: page)
        protected.on(.POST, "import", body: .collect(maxSize: "10mb"), use: upload)
        protected.get("import", "progress", use: progress)
        protected.post("import", "retry", use: retry)
        protected.get("import", "mappings", ":mappingID", "search", use: searchCandidates)
        protected.post("import", "mappings", ":mappingID", "accept", use: accept)
        protected.post("import", "mappings", ":mappingID", "ignore", use: ignore)
        protected.post("import", "mappings", ":mappingID", "reset", use: reset)
        protected.post("import", "mappings", ":mappingID", "change", use: change)
        protected.get("import", "rows", ":rowID", "options", use: rowOptions)
        protected.post("import", "rows", ":rowID", "assign", use: assignRow)
        protected.post("import", "rows", ":rowID", "ignore", use: ignoreRow)
    }

    // MARK: Page & upload

    func page(req: Request) async throws -> HTMLResponse {
        HTMLResponse(ImportPage(navContext: try req.nav(.importing), summary: nil, error: nil, state: try await state(req)))
    }

    func upload(req: Request) async throws -> HTMLResponse {
        let nav = try req.nav(.importing)
        let input = try req.content.decode(UploadInput.self)
        // Also enforced by the route's body limit; checked here for already-collected bodies.
        guard input.file.data.readableBytes <= 10 * 1024 * 1024 else { throw Abort(.payloadTooLarge) }
        func failure(_ message: String) async throws -> HTMLResponse {
            HTMLResponse(status: .unprocessableEntity, ImportPage(navContext: nav, summary: nil, error: message, state: try await state(req)))
        }
        guard let text = String(data: Data(input.file.data.readableBytesView), encoding: .utf8) else {
            return try await failure("Die Datei ist nicht UTF-8-kodiert.")
        }
        do {
            let summary = try await ImportService(db: req.db).ingest(text: text, filename: input.file.filename, userID: try req.userID)
            await req.application.matchingWorker.kick()
            return HTMLResponse(ImportPage(navContext: nav, summary: summary, error: nil, state: try await state(req)))
        } catch let error as NetflixCSVError {
            return try await failure(error.germanMessage)
        }
    }

    /// Progress fragment; when a polling request finds the run finished, the page reloads once.
    func progress(req: Request) async throws -> HTMLResponse {
        var fragment = try await progressFragment(req)
        fragment.finished = (try? req.query.get(String.self, at: "polling")) == "1"
        return HTMLResponse(fragment)
    }

    /// Starts a matching run now (e.g. after TMDB was down) and returns the progress fragment.
    func retry(req: Request) async throws -> HTMLResponse {
        await req.application.matchingWorker.kick()
        return HTMLResponse(try await progressFragment(req))
    }

    // MARK: Decisions

    func searchCandidates(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let mapping = try await req.mappings.ownMapping(userID: try req.userID, mappingID: try uuid(req, "mappingID"))
            let mode = (try? req.query.get(String.self, at: "mode")) == "change" ? "change" : "accept"
            let query = ((try? req.query.get(String.self, at: "q")) ?? "").trimmingCharacters(in: .whitespaces)
            let results = query.count >= 2 ? try await req.tmdb.searchMulti(query) : []
            return HTMLResponse(CandidateList(mappingID: try mapping.requireID(), results: Array(results.prefix(10)), action: mode,
                                              target: mode == "change" ? "closest .mapping-item" : "closest .mapping-review"))
        }
    }

    func accept(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            let input = try req.content.decode(DecisionInput.self)
            try await req.mappings.accept(userID: userID, mappingID: id, kind: try kind(input.kind), tmdbID: input.tmdbID)
            return HTMLResponse(EmptyHTML())
        }
    }

    func ignore(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            try await req.mappings.ignore(userID: userID, mappingID: id)
            return HTMLResponse(EmptyHTML())
        }
    }

    func reset(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            try await req.mappings.reset(userID: userID, mappingID: id)
            return try await listItem(req, userID: userID, mappingID: id)
        }
    }

    func change(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            let input = try req.content.decode(DecisionInput.self)
            try await req.mappings.change(userID: userID, mappingID: id, kind: try kind(input.kind), tmdbID: input.tmdbID)
            return try await listItem(req, userID: userID, mappingID: id)
        }
    }

    /// Episode picker for one unmatched row (episodes of the series its name is mapped to).
    func rowOptions(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let row = try await req.mappings.ownRow(userID: try req.userID, rowID: try uuid(req, "rowID"))
            guard let mappingID = row.$mapping.id, let mapping = try await NetflixMapping.find(mappingID, on: req.db),
                  mapping.titleKind == .tv, let titleID = mapping.$title.id else { throw TrackingError.notFound }
            return HTMLResponse(AssignForm(rowID: try row.requireID(), episodes: try await req.catalog.episodes(of: titleID)))
        }
    }

    func assignRow(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let input = try req.content.decode(AssignInput.self)
            try await req.mappings.assignRow(userID: try req.userID, rowID: try uuid(req, "rowID"), episodeID: input.episodeID)
            return HTMLResponse(headers: ["HX-Trigger": "importChanged"], EmptyHTML())
        }
    }

    func ignoreRow(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            try await req.mappings.ignoreRow(userID: try req.userID, rowID: try uuid(req, "rowID"))
            return HTMLResponse(headers: ["HX-Trigger": "importChanged"], EmptyHTML())
        }
    }

    // MARK: Helpers

    /// Runs a mapping decision, kicks the worker and tells the page that import state changed.
    private func decide(_ req: Request, _ body: (UUID, UUID) async throws -> HTMLResponse) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            var response = try await body(try req.userID, try uuid(req, "mappingID"))
            await req.application.matchingWorker.kick()
            response.headers.replaceOrAdd(name: "HX-Trigger", value: "importChanged")
            return response
        }
    }

    private func listItem(_ req: Request, userID: UUID, mappingID: UUID) async throws -> HTMLResponse {
        let mapping = try await req.mappings.ownMapping(userID: userID, mappingID: mappingID)
        let titleName = try await mapping.$title.get(on: req.db)?.name
        return HTMLResponse(MappingListItem(mapping: mapping, titleName: titleName))
    }

    private func uuid(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    private func kind(_ raw: String) throws -> TitleKind {
        guard let kind = TitleKind(rawValue: raw) else { throw Abort(.badRequest) }
        return kind
    }

    private func progressFragment(_ req: Request) async throws -> ImportProgress {
        try await req.importState.progress(userID: try req.userID)
    }

    func state(_ req: Request) async throws -> ImportState {
        try await req.importState.state(userID: try req.userID, mappingFilter: (try? req.query.get(String.self, at: "status")) ?? "all")
    }
}
