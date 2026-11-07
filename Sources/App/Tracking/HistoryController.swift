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
        let page = max(1, (try? req.query.get(Int.self, at: "page")) ?? 1)
        let watches = try await req.watches.watchesQuery(userID: try req.userID)
            .filter(\.$watchedOn != nil)
            .sort(\.$watchedOn, .descending).sort(\.$createdAt, .descending)
            .offset((page - 1) * Self.pageSize).limit(Self.pageSize + 1)
            .with(\.$title).with(\.$episode)
            .all()
        let rows = HistoryRows(rows: watches.prefix(Self.pageSize).map { ($0, $0.title, $0.episode) },
                               nextPage: watches.count > Self.pageSize ? page + 1 : nil, today: req.watches.today())
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
            try await req.watches.editWatch(userID: try req.userID, watchID: id, day: day, service: service)
            guard let watch = try await Watch.query(on: req.db).filter(\.$id == id).with(\.$title).with(\.$episode).first() else {
                throw TrackingError.notFound
            }
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
