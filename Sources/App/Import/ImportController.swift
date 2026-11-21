import Fluent
import Vapor

/// Web front door of the Netflix import (the „Import“ page under `/import`).
struct ImportController {
    /// Multipart form with the uploaded CSV file.
    struct UploadInput: Content { var file: File }
    /// Form of an accept/change decision: the chosen title's kind (`tv`/`movie`) and TMDB ID.
    struct DecisionInput: Content { var kind: String; var tmdbID: Int }
    /// Form of a manual episode assignment.
    struct AssignInput: Content { var episodeID: UUID }

    /// Error shown when the upload is not a Netflix viewing history.
    static let notNetflixMessage = "Das ist keine Netflix-Wiedergabeaktivität (erwartet wird die Kopfzeile „Title,Date“)."
    /// How many of the newest unmatched rows the page lists.
    static let unmatchedLimit = ImportStateService.unmatchedLimit

    /// Registers the import routes on the authenticated route group.
    /// - Parameter protected: The route group requiring a logged-in user.
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

    /// `GET /import`: renders the import page with the current state.
    /// - Parameter req: The request (`status` query filters the mapping list).
    /// - Returns: The import page.
    /// - Throws: A database error.
    func page(req: Request) async throws -> HTMLResponse {
        HTMLResponse(ImportPage(navContext: try req.nav(.importing), summary: nil, error: nil, state: try await state(req)))
    }

    /// `POST /import`: stores an uploaded Netflix export (at most 10 MB), kicks the matching worker and renders the page
    /// with the upload summary; a non-UTF-8 or invalid file renders the page with an error and status 422.
    /// - Parameter req: The request with the multipart `file`.
    /// - Returns: The import page.
    /// - Throws: `Abort(.payloadTooLarge)` above 10 MB, a decoding or database error.
    func upload(req: Request) async throws -> HTMLResponse {
        let nav = try req.nav(.importing)
        let input = try req.content.decode(UploadInput.self)
        // Also enforced by the route's body limit; checked here for already-collected bodies.
        guard input.file.data.readableBytes <= 10 * 1024 * 1024 else { throw Abort(.payloadTooLarge) }
        /// Renders the import page with an error and status 422.
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

    /// Progress fragment; when a polling request finds the run finished, it shows „Zuordnung abgeschlossen“ (matching
    /// done) with a reload link instead of forcing a reload.
    ///
    /// `GET /import/progress`.
    /// - Parameter req: The request; `polling=1` marks a request from the polling element.
    /// - Returns: The progress fragment.
    /// - Throws: A database error.
    func progress(req: Request) async throws -> HTMLResponse {
        var fragment = try await progressFragment(req)
        fragment.finished = (try? req.query.get(String.self, at: "polling")) == "1"
        return HTMLResponse(fragment)
    }

    /// Starts a matching run now (e.g. after TMDB was down) and returns the progress fragment.
    ///
    /// `POST /import/retry`.
    /// - Parameter req: The request.
    /// - Returns: The progress fragment.
    /// - Throws: A database error.
    func retry(req: Request) async throws -> HTMLResponse {
        await req.application.matchingWorker.kick()
        return HTMLResponse(try await progressFragment(req))
    }

    // MARK: Decisions

    /// `GET /import/mappings/:mappingID/search`: searches TMDB (movies and series) for `q` (at least 2 characters) and
    /// renders up to 10 candidates for accepting (`mode=accept`, default) or changing (`mode=change`) the mapping.
    /// - Parameter req: The request with `q` and `mode` query parameters.
    /// - Returns: The candidate list fragment.
    /// - Throws: `TrackingError.notFound` for a foreign mapping, `TMDBError` from the search.
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

    /// `POST /import/mappings/:mappingID/accept`: confirms a reviewed name as the chosen title.
    /// - Parameter req: The request with a `DecisionInput` form.
    /// - Returns: An empty fragment (removes the review item) with `HX-Trigger: importChanged`.
    /// - Throws: `Abort(.badRequest)` for an unknown kind, `TrackingError.notFound` for a foreign mapping, `TMDBError`.
    func accept(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            let input = try req.content.decode(DecisionInput.self)
            try await req.mappings.accept(userID: userID, mappingID: id, kind: try kind(input.kind), tmdbID: input.tmdbID)
            return HTMLResponse(EmptyHTML())
        }
    }

    /// `POST /import/mappings/:mappingID/ignore`: ignores a name and its open rows.
    /// - Parameter req: The request.
    /// - Returns: An empty fragment with `HX-Trigger: importChanged`.
    /// - Throws: `TrackingError.notFound` for a foreign mapping.
    func ignore(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            try await req.mappings.ignore(userID: userID, mappingID: id)
            return HTMLResponse(EmptyHTML())
        }
    }

    /// `POST /import/mappings/:mappingID/reset`: undoes a mapping so the worker resolves the name again.
    /// - Parameter req: The request.
    /// - Returns: The updated mapping list item with `HX-Trigger: importChanged`.
    /// - Throws: `TrackingError.notFound` for a foreign mapping.
    func reset(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            try await req.mappings.reset(userID: userID, mappingID: id)
            return try await listItem(req, userID: userID, mappingID: id)
        }
    }

    /// `POST /import/mappings/:mappingID/change`: re-points a name to another title.
    /// - Parameter req: The request with a `DecisionInput` form.
    /// - Returns: The updated mapping list item with `HX-Trigger: importChanged`.
    /// - Throws: `Abort(.badRequest)` for an unknown kind, `TrackingError.notFound` for a foreign mapping, `TMDBError`.
    func change(req: Request) async throws -> Response {
        try await decide(req) { userID, id in
            let input = try req.content.decode(DecisionInput.self)
            try await req.mappings.change(userID: userID, mappingID: id, kind: try kind(input.kind), tmdbID: input.tmdbID)
            return try await listItem(req, userID: userID, mappingID: id)
        }
    }

    /// Episode picker for one unmatched row (episodes of the series its name is mapped to).
    ///
    /// `GET /import/rows/:rowID/options`.
    /// - Parameter req: The request.
    /// - Returns: The assign form fragment.
    /// - Throws: `TrackingError.notFound` for a foreign row or one whose name is not mapped to a series.
    func rowOptions(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let row = try await req.mappings.ownRow(userID: try req.userID, rowID: try uuid(req, "rowID"))
            guard let mappingID = row.$mapping.id, let mapping = try await NetflixMapping.find(mappingID, on: req.db),
                  mapping.titleKind == .tv, let titleID = mapping.$title.id else { throw TrackingError.notFound }
            return HTMLResponse(AssignForm(rowID: try row.requireID(), episodes: try await req.catalog.episodes(of: titleID)))
        }
    }

    /// `POST /import/rows/:rowID/assign`: assigns an unmatched row to the chosen episode.
    /// - Parameter req: The request with an `AssignInput` form.
    /// - Returns: An empty fragment with `HX-Trigger: importChanged`.
    /// - Throws: `TrackingError.notFound` for a foreign row or unknown episode.
    func assignRow(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let input = try req.content.decode(AssignInput.self)
            try await req.mappings.assignRow(userID: try req.userID, rowID: try uuid(req, "rowID"), episodeID: input.episodeID)
            return HTMLResponse(headers: ["HX-Trigger": "importChanged"], EmptyHTML())
        }
    }

    /// `POST /import/rows/:rowID/ignore`: ignores a single row.
    /// - Parameter req: The request.
    /// - Returns: An empty fragment with `HX-Trigger: importChanged`.
    /// - Throws: `TrackingError.notFound` for a foreign row.
    func ignoreRow(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            try await req.mappings.ignoreRow(userID: try req.userID, rowID: try uuid(req, "rowID"))
            return HTMLResponse(headers: ["HX-Trigger": "importChanged"], EmptyHTML())
        }
    }

    // MARK: Helpers

    /// Runs a mapping decision, kicks the worker and tells the page that import state changed.
    ///
    /// - Parameters:
    ///   - req: The request with a `mappingID` path parameter.
    ///   - body: The decision, given the user ID and mapping ID; returns the fragment to send.
    /// - Returns: The fragment's response with `HX-Trigger: importChanged`.
    /// - Throws: `Abort(.notFound)` for a malformed ID, or whatever `body` throws.
    private func decide(_ req: Request, _ body: (UUID, UUID) async throws -> HTMLResponse) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            var response = try await body(try req.userID, try uuid(req, "mappingID"))
            await req.application.matchingWorker.kick()
            response.headers.replaceOrAdd(name: "HX-Trigger", value: "importChanged")
            return response
        }
    }

    /// Renders one mapping's list item with its current title name.
    /// - Parameters:
    ///   - req: The request.
    ///   - userID: The logged-in user.
    ///   - mappingID: The user's mapping.
    /// - Returns: The mapping list item fragment.
    /// - Throws: `TrackingError.notFound` for a foreign mapping.
    private func listItem(_ req: Request, userID: UUID, mappingID: UUID) async throws -> HTMLResponse {
        let mapping = try await req.mappings.ownMapping(userID: userID, mappingID: mappingID)
        let titleName = try await mapping.$title.get(on: req.db)?.name
        return HTMLResponse(MappingListItem(mapping: mapping, titleName: titleName))
    }

    /// Reads a UUID path parameter.
    /// - Parameters:
    ///   - req: The request.
    ///   - name: The parameter name.
    /// - Returns: The parsed UUID.
    /// - Throws: `Abort(.notFound)` when missing or malformed.
    private func uuid(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    /// Parses a title kind from a form value.
    /// - Parameter raw: `tv` or `movie`.
    /// - Returns: The title kind.
    /// - Throws: `Abort(.badRequest)` for any other value.
    private func kind(_ raw: String) throws -> TitleKind {
        guard let kind = TitleKind(rawValue: raw) else { throw Abort(.badRequest) }
        return kind
    }

    /// The logged-in user's import progress.
    /// - Parameter req: The request.
    /// - Returns: The progress fragment.
    /// - Throws: A database error.
    private func progressFragment(_ req: Request) async throws -> ImportProgress {
        try await req.importState.progress(userID: try req.userID)
    }

    /// The logged-in user's import state, filtered by the `status` query parameter.
    /// - Parameter req: The request.
    /// - Returns: The state for the import page.
    /// - Throws: A database error.
    func state(_ req: Request) async throws -> ImportState {
        try await req.importState.state(userID: try req.userID, mappingFilter: (try? req.query.get(String.self, at: "status")) ?? "all")
    }
}
