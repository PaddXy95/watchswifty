import Fluent
import Vapor

/// Web routes of the „Verlauf“ (history) page and of editing or deleting single watches.
struct HistoryController {
    static let pageSize = 50

    /// Form body of `POST /watches/:watchID`: the new day and service; empty strings mean none.
    struct EditInput: Content { var day: String?; var service: String? }

    /// Registers the history page and the watch edit/delete routes.
    /// - Parameter protected: The route group that requires a logged-in user.
    func register(on protected: any RoutesBuilder) {
        protected.get("history", use: history)
        protected.post("watches", ":watchID", use: edit)
        protected.delete("watches", ":watchID", use: delete)
    }

    /// Serves `GET /history`: renders the full „Verlauf“ page, or, for htmx requests of page 2 and later (the
    /// „Mehr laden“ (load more) button), only the next batch of rows.
    /// - Parameter req: The request; the `page` query parameter is clamped to 1…``HistoryService/maxPage``.
    /// - Returns: The full page or the rows fragment.
    /// - Throws: An authentication error without a logged-in user, or database errors.
    func history(req: Request) async throws -> HTMLResponse {
        let page = min(max(1, (try? req.query.get(Int.self, at: "page")) ?? 1), HistoryService.maxPage)
        let result = try await req.history.page(userID: try req.userID, page: page, perPage: Self.pageSize)
        let rows = HistoryRows(rows: result.entries.map { ($0, $0.title, $0.episode) },
                               nextPage: page * Self.pageSize < result.total ? page + 1 : nil, today: req.watches.today())
        if page > 1 && req.isHTMX { return HTMLResponse(rows) }
        return HTMLResponse(HistoryPage(nav: try req.nav(.history), rows: rows))
    }

    /// Serves `POST /watches/:watchID`: changes the day and service of one of the user's watches and returns the
    /// updated history row fragment.
    /// - Parameter req: The request with an ``EditInput`` body.
    /// - Returns: The updated ``HistoryRow`` fragment.
    /// - Throws: `Abort(.badRequest)` for an unknown service, `Abort(.notFound)` for a malformed ID,
    ///   `TrackingError.notFound` for another user's or a missing watch, `.invalidDate` or `.futureDate` for a bad day.
    func edit(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            let id = try watchID(req)
            let input = try req.content.decode(EditInput.self)
            let service: StreamingService?
            if let raw = input.service, !raw.isEmpty {
                guard let parsed = StreamingService(rawValue: raw) else { throw Abort(.badRequest, reason: "Unbekannter Dienst") }
                service = parsed
            } else {
                service = nil
            }
            let day = input.day.flatMap { $0.isEmpty ? nil : $0 }
            let watch = try await req.history.edit(userID: try req.userID, watchID: id, day: day, service: service)
            return HTMLResponse(HistoryRow(watch: watch, title: watch.title, episode: watch.episode, today: req.watches.today()))
        }
    }

    /// Serves `DELETE /watches/:watchID`: deletes one of the user's watches and returns an empty fragment, so htmx removes
    /// the row.
    /// - Parameter req: The request.
    /// - Returns: An empty fragment.
    /// - Throws: `Abort(.notFound)` for a malformed ID, `TrackingError.notFound` for another user's or a missing watch.
    func delete(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            try await req.watches.deleteWatch(userID: try req.userID, watchID: try watchID(req))
            return HTMLResponse(EmptyHTML())
        }
    }

    /// Reads the `watchID` route parameter.
    /// - Parameter req: The request.
    /// - Returns: The watch ID.
    /// - Throws: `Abort(.notFound)` when the parameter is not a UUID.
    private func watchID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("watchID", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }
}
