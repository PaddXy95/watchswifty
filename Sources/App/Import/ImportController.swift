import Fluent
import Vapor

struct ImportController {
    struct UploadInput: Content { var file: File }
    struct DecisionInput: Content { var kind: String; var tmdbID: Int }
    struct AssignInput: Content { var episodeID: UUID }

    static let notNetflixMessage = "Das ist keine Netflix-Wiedergabeaktivität (erwartet wird die Kopfzeile „Title,Date“)."
    static let unmatchedLimit = 50

    func register(on protected: any RoutesBuilder) {
        protected.get("import", use: page)
        protected.on(.POST, "import", body: .collect(maxSize: "10mb"), use: upload)
        protected.get("import", "progress", use: progress)
        protected.get("import", "mappings", ":mappingID", "search", use: searchCandidates)
        protected.post("import", "mappings", ":mappingID", "accept", use: accept)
        protected.post("import", "mappings", ":mappingID", "ignore", use: ignore)
        protected.post("import", "mappings", ":mappingID", "reset", use: reset)
        protected.post("import", "mappings", ":mappingID", "change", use: change)
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
        } catch NetflixCSVError.notNetflixHistory {
            return try await failure(Self.notNetflixMessage)
        } catch let NetflixCSVError.invalidDate(line, value) {
            return try await failure("Zeile \(line): ungültiges Datum „\(value)“.")
        }
    }

    /// Progress fragment; when a polling request finds the run finished, the page reloads once.
    func progress(req: Request) async throws -> HTMLResponse {
        let fragment = try await progressFragment(req)
        if !fragment.isRunning, (try? req.query.get(String.self, at: "polling")) == "1" {
            return HTMLResponse(headers: ["HX-Refresh": "true"], fragment)
        }
        return HTMLResponse(fragment)
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
        let userID = try req.userID
        let worker = req.application.matchingWorker
        let review = try await NetflixMapping.query(on: req.db).filter(\.$user.$id == userID)
            .filter(\.$status == MappingStatus.review.rawValue).all().compactMap(\.id)
        let pending = try await NetflixRow.query(on: req.db).filter(\.$user.$id == userID)
            .filter(\.$status == RowStatus.pending.rawValue).all()
        let waiting = pending.filter { $0.$mapping.id.map(review.contains) ?? false }.count
        return ImportProgress(isRunning: await worker.isRunning, pendingRows: pending.count - waiting,
                              waitingForReview: waiting, lastError: await worker.lastError(for: userID))
    }

    func state(_ req: Request) async throws -> ImportState {
        let userID = try req.userID
        let filter = ["auto", "confirmed", "ignored"].contains((try? req.query.get(String.self, at: "status")) ?? "")
            ? try req.query.get(String.self, at: "status") : "all"
        let mappings = try await NetflixMapping.query(on: req.db).filter(\.$user.$id == userID).with(\.$title)
            .sort(\.$netflixName).all()
        let rows = try await NetflixRow.query(on: req.db).filter(\.$user.$id == userID)
            .filter(\.$status ~~ [RowStatus.pending.rawValue, RowStatus.unmatched.rawValue]).all()
        let pendingByMapping = Dictionary(grouping: rows.filter { $0.rowStatus == .pending }, by: { $0.$mapping.id })

        let review = mappings.filter { $0.mappingStatus == .review }
            .map { ReviewItem(mapping: $0, rowCount: pendingByMapping[$0.id]?.count ?? 0) }
            .filter { $0.rowCount > 0 }
        let unmatchedRows = rows.filter { $0.rowStatus == .unmatched }.sorted { $0.watchedOn > $1.watchedOn }
        let mappingByID = Dictionary(mappings.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        var episodesByTitle: [UUID: [Episode]] = [:]
        var unmatched: [UnmatchedItem] = []
        for row in unmatchedRows.prefix(Self.unmatchedLimit) {
            var episodes: [Episode] = []
            if let mappingID = row.$mapping.id, let mapping = mappingByID[mappingID], mapping.titleKind == .tv, let titleID = mapping.$title.id {
                if episodesByTitle[titleID] == nil { episodesByTitle[titleID] = try await req.catalog.episodes(of: titleID) }
                episodes = episodesByTitle[titleID] ?? []
            }
            unmatched.append(UnmatchedItem(row: row, episodes: episodes))
        }
        let listed = mappings.filter { mapping in
            switch filter {
            case "auto", "confirmed", "ignored": mapping.status == filter
            default: mapping.mappingStatus != .review
            }
        }
        return ImportState(progress: try await progressFragment(req), review: review, unmatched: unmatched,
                           unmatchedTotal: unmatchedRows.count, mappings: listed.map { ($0, $0.title?.name) }, mappingFilter: filter)
    }
}
