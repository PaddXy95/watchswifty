import Fluent
import Foundation
import OpenAPIRuntime
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func uploadNetflix(_ input: Operations.uploadNetflix.Input) async throws -> Operations.uploadNetflix.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .multipartForm(form) = input.body else { throw APIError.validation("Keine Datei hochgeladen.") }
        let upload = try await uploadedFile(form, limit: 10 * 1024 * 1024) { part in
            if case let .file(file) = part { return (file.payload.body, file.filename) }
            return nil
        }
        do {
            let summary = try await ImportService(db: request.db).ingest(text: try uploadedText(upload.data), filename: upload.filename,
                                                                        userID: user.requireID())
            await request.application.matchingWorker.kick()
            return .ok(.init(body: .json(.init(new: summary.new, known: summary.known, skipped: summary.skipped))))
        } catch let error as NetflixCSVError {
            throw APIError.validation(error.germanMessage)
        }
    }

    func getNetflixImport(_ input: Operations.getNetflixImport.Input) async throws -> Operations.getNetflixImport.Output {
        let user = try APIContext.requireUser()
        let state = try await APIContext.request().importState.state(userID: user.requireID(),
                                                                     mappingFilter: input.query.mappings?.rawValue ?? "all")
        return .ok(.init(body: .json(.init(
            progress: Self.progress(state.progress),
            review: state.review.map { item in
                .init(id: item.mapping.id?.uuidString ?? "", netflixName: item.mapping.netflixName,
                      kind: item.mapping.titleKind == .movie ? .movie : .tv, rowCount: item.rowCount,
                      candidates: item.mapping.candidateResults.map(Self.searchResult))
            },
            unmatched: state.unmatched.map { .init(id: $0.row.id?.uuidString ?? "", rawTitle: $0.row.rawTitle, day: $0.row.watchedOn, canAssign: $0.canAssign) },
            unmatchedTotal: state.unmatchedTotal,
            mappings: state.mappings.map { Self.mapping($0.0, titleName: $0.1) }))))
    }

    func retryNetflix(_ input: Operations.retryNetflix.Input) async throws -> Operations.retryNetflix.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        await request.application.matchingWorker.kick()
        return .ok(.init(body: .json(Self.progress(try await request.importState.progress(userID: user.requireID())))))
    }

    func acceptMapping(_ input: Operations.acceptMapping.Input) async throws -> Operations.acceptMapping.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        return .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.accept(userID: userID, mappingID: id, kind: body.kind == .movie ? .movie : .tv, tmdbID: body.tmdbId)
        })))
    }

    func changeMapping(_ input: Operations.changeMapping.Input) async throws -> Operations.changeMapping.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        return .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.change(userID: userID, mappingID: id, kind: body.kind == .movie ? .movie : .tv, tmdbID: body.tmdbId)
        })))
    }

    func ignoreMapping(_ input: Operations.ignoreMapping.Input) async throws -> Operations.ignoreMapping.Output {
        .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.ignore(userID: userID, mappingID: id)
        })))
    }

    func resetMapping(_ input: Operations.resetMapping.Input) async throws -> Operations.resetMapping.Output {
        .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.reset(userID: userID, mappingID: id)
        })))
    }

    func searchMappingCandidates(_ input: Operations.searchMappingCandidates.Input) async throws -> Operations.searchMappingCandidates.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        _ = try await request.mappings.ownMapping(userID: user.requireID(), mappingID: id)
        let query = input.query.q.trimmingCharacters(in: .whitespaces)
        let results = query.count >= 2 ? try await request.tmdb.searchMulti(query) : []
        return .ok(.init(body: .json(results.prefix(10).map(Self.searchResult))))
    }

    func getRowOptions(_ input: Operations.getRowOptions.Input) async throws -> Operations.getRowOptions.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let row = try await request.mappings.ownRow(userID: user.requireID(), rowID: id)
        guard let mappingID = row.$mapping.id, let mapping = try await NetflixMapping.find(mappingID, on: request.db),
              mapping.titleKind == .tv, let titleID = mapping.$title.id else { throw APIError.notFound }
        let episodes = try await request.catalog.episodes(of: titleID)
        return .ok(.init(body: .json(episodes.map { .init(episodeId: $0.id?.uuidString ?? "", code: $0.code, name: $0.name) })))
    }

    func assignRow(_ input: Operations.assignRow.Input) async throws -> Operations.assignRow.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id), case let .json(body) = input.body,
              let episodeID = UUID(uuidString: body.episodeId) else { throw APIError.notFound }
        try await APIContext.request().mappings.assignRow(userID: user.requireID(), rowID: id, episodeID: episodeID)
        return .noContent(.init())
    }

    func ignoreRow(_ input: Operations.ignoreRow.Input) async throws -> Operations.ignoreRow.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().mappings.ignoreRow(userID: user.requireID(), rowID: id)
        return .noContent(.init())
    }

    /// Runs a mapping decision for the signed-in user's mapping, kicks the worker and returns the mapping.
    private func decideMapping(_ rawID: String, _ decide: (Request, UUID, UUID) async throws -> Void) async throws -> Components.Schemas.Mapping {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: rawID) else { throw APIError.notFound }
        try await decide(request, try user.requireID(), id)
        await request.application.matchingWorker.kick()
        let mapping = try await request.mappings.ownMapping(userID: user.requireID(), mappingID: id)
        return Self.mapping(mapping, titleName: try await mapping.$title.get(on: request.db)?.name)
    }

    static func mapping(_ mapping: NetflixMapping, titleName: String?) -> Components.Schemas.Mapping {
        .init(id: mapping.id?.uuidString ?? "", netflixName: mapping.netflixName, kind: mapping.titleKind == .movie ? .movie : .tv,
              status: Components.Schemas.Mapping.statusPayload(rawValue: mapping.status) ?? .pending,
              title: mapping.$title.value.flatMap { $0 }.map { .init(tmdbId: $0.tmdbID, name: titleName ?? $0.name) })
    }

    static func progress(_ progress: ImportProgress) -> Components.Schemas.ImportProgress {
        .init(running: progress.isRunning, pendingRows: progress.pendingRows, waitingForReview: progress.waitingForReview,
              lastError: progress.lastError)
    }
}
