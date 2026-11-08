import Fluent
import Vapor

struct HistoryController {
    static let pageSize = 50

    struct EditInput: Content { var day: String?; var service: String? }

    func register(on protected: any RoutesBuilder) {
        protected.get("history", use: history)
        protected.post("watches", ":watchID", use: edit)
        protected.delete("watches", ":watchID", use: delete)
    }

    func history(req: Request) async throws -> HTMLResponse {
        let page = min(max(1, (try? req.query.get(Int.self, at: "page")) ?? 1), HistoryService.maxPage)
        let result = try await req.history.page(userID: try req.userID, page: page, perPage: Self.pageSize)
        let rows = HistoryRows(rows: result.entries.map { ($0, $0.title, $0.episode) },
                               nextPage: page * Self.pageSize < result.total ? page + 1 : nil, today: req.watches.today())
        if page > 1 && req.isHTMX { return HTMLResponse(rows) }
        return HTMLResponse(HistoryPage(nav: try req.nav(.history), rows: rows))
    }

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

    func delete(req: Request) async throws -> Response {
        try await respondMappingTrackingErrors(req) {
            try await req.watches.deleteWatch(userID: try req.userID, watchID: try watchID(req))
            return HTMLResponse(EmptyHTML())
        }
    }

    private func watchID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("watchID", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }
}
