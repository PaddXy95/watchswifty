import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getHistory(_ input: Operations.getHistory.Input) async throws -> Operations.getHistory.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let page = max(1, input.query.page ?? 1)
        let perPage = min(200, max(1, input.query.perPage ?? 50))
        let result = try await request.history.page(userID: user.requireID(), page: page, perPage: perPage)
        return .ok(.init(body: .json(.init(items: result.entries.map(Self.historyItem), total: result.total, page: page, perPage: perPage))))
    }

    func updateWatch(_ input: Operations.updateWatch.Input) async throws -> Operations.updateWatch.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let body: Components.Schemas.WatchEdit? = if case let .json(value)? = input.body { value } else { nil }
        let watch = try await APIContext.request().history.edit(
            userID: user.requireID(), watchID: id, day: body?.day.flatMap { $0.isEmpty ? nil : $0 },
            service: body?.service.flatMap { StreamingService(rawValue: $0.rawValue) })
        return .ok(.init(body: .json(Self.historyItem(watch))))
    }

    func deleteWatch(_ input: Operations.deleteWatch.Input) async throws -> Operations.deleteWatch.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().watches.deleteWatch(userID: user.requireID(), watchID: id)
        return .noContent(.init())
    }

    static func historyItem(_ watch: Watch) -> Components.Schemas.HistoryItem {
        let title = watch.$title.value
        return .init(id: watch.id?.uuidString ?? "", kind: title?.titleKind == .movie ? .movie : .tv, tmdbId: title?.tmdbID ?? 0,
                     title: title?.name ?? "", episode: watch.$episode.value.flatMap { $0 }.map { .init(season: $0.season, number: $0.number, name: $0.name) },
                     day: watch.watchedOn, service: watch.service.flatMap { Components.Schemas.Service(rawValue: $0) },
                     origin: watch.watchOrigin == .import ? ._import : .manual)
    }
}
