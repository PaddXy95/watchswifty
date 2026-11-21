import Fluent
import Foundation
import OpenAPIRuntime
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `POST /api/v1/imports/netflix`: stores the rows of a Netflix viewing history CSV
    /// (`ImportService.ingest`, rows from an earlier upload are not stored again) and wakes the `MatchingWorker`.
    /// - Parameter input: The generated operation input (multipart form with the UTF-8 file, at most 10 MB).
    /// - Returns: `.ok` with the numbers of new rows, already known rows and rows skipped for lacking a usable title.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token,
    ///   `APIError.payloadTooLarge` for a too large file, `APIError.validation` without a file, for a non-UTF-8 file or
    ///   with the German message of a `NetflixCSVError` (invalid file, too many rows).
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

    /// Handles `GET /api/v1/imports/netflix`: progress, names waiting for review, unmatched rows and the mappings
    /// (filtered by `mappings`) from `ImportStateService`.
    /// - Parameter input: The generated operation input (optional query `mappings`, default `all`).
    /// - Returns: `.ok` with the import state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getNetflixImport(_ input: Operations.getNetflixImport.Input) async throws -> Operations.getNetflixImport.Output {
        let user = try APIContext.requireUser()
        let state = try await APIContext.request().importState.state(userID: user.requireID(),
                                                                     mappingFilter: input.query.mappings?.rawValue ?? "all")
        return .ok(.init(body: .json(.init(
            progress: Self.progress(state.progress),
            review: state.review.map { item in
                .init(id: item.mapping.id?.uuidString ?? "", netflixName: item.mapping.netflixName,
                      kind: item.mapping.titleKind == .movie ? .movie : .tv, rowCount: item.rowCount,
                      candidates: item.mapping.candidateResults.map(Self.searchResult),
                      firstDay: item.firstDay, lastDay: item.lastDay,
                      rows: item.shownRows.map { .init(rawTitle: $0.rawTitle, day: $0.watchedOn) })
            },
            unmatched: state.unmatched.map { .init(id: $0.row.id?.uuidString ?? "", rawTitle: $0.row.rawTitle, day: $0.row.watchedOn, canAssign: $0.canAssign) },
            unmatchedTotal: state.unmatchedTotal,
            mappings: state.mappings.map { Self.mapping($0.0, titleName: $0.1) }))))
    }

    /// Handles `POST /api/v1/imports/netflix/retry`: wakes the `MatchingWorker` and reports the progress.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the import progress.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func retryNetflix(_ input: Operations.retryNetflix.Input) async throws -> Operations.retryNetflix.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        await request.application.matchingWorker.kick()
        return .ok(.init(body: .json(Self.progress(try await request.importState.progress(userID: user.requireID())))))
    }

    /// Handles `POST /api/v1/imports/netflix/mappings/{id}/accept`: confirms a Netflix name as the given TMDB title
    /// (`MappingService.accept`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with kind and `tmdbId`).
    /// - Returns: `.ok` with the updated mapping.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `APIError.notFound` for a malformed ID, `TrackingError.notFound` for an unknown or another
    ///   user's mapping, `TMDBError` when the title is not available.
    func acceptMapping(_ input: Operations.acceptMapping.Input) async throws -> Operations.acceptMapping.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        return .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.accept(userID: userID, mappingID: id, kind: body.kind == .movie ? .movie : .tv, tmdbID: body.tmdbId)
        })))
    }

    /// Handles `POST /api/v1/imports/netflix/mappings/{id}/change`: re-points a Netflix name to another TMDB title
    /// (`MappingService.change`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with kind and `tmdbId`).
    /// - Returns: `.ok` with the updated mapping.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, `APIError.notFound` for a malformed ID, `TrackingError.notFound` for an unknown or another
    ///   user's mapping, `TMDBError` when the title is not available.
    func changeMapping(_ input: Operations.changeMapping.Input) async throws -> Operations.changeMapping.Output {
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        return .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.change(userID: userID, mappingID: id, kind: body.kind == .movie ? .movie : .tv, tmdbID: body.tmdbId)
        })))
    }

    /// Handles `POST /api/v1/imports/netflix/mappings/{id}/ignore`: ignores a Netflix name and its open rows
    /// (`MappingService.ignore`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.ok` with the updated mapping.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's mapping.
    func ignoreMapping(_ input: Operations.ignoreMapping.Input) async throws -> Operations.ignoreMapping.Output {
        .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.ignore(userID: userID, mappingID: id)
        })))
    }

    /// Handles `POST /api/v1/imports/netflix/mappings/{id}/reset`: deletes the import watches created from the name and
    /// lets the worker resolve it again (`MappingService.reset`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.ok` with the updated mapping.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's mapping.
    func resetMapping(_ input: Operations.resetMapping.Input) async throws -> Operations.resetMapping.Output {
        .ok(.init(body: .json(try await decideMapping(input.path.id) { request, userID, id in
            try await request.mappings.reset(userID: userID, mappingID: id)
        })))
    }

    /// Handles `GET /api/v1/imports/netflix/mappings/{id}/search`: TMDB multi search (at most 10 hits) for picking the
    /// title of one of the user's mappings; queries shorter than two characters return no hits.
    /// - Parameter input: The generated operation input (path `id`, query `q`).
    /// - Returns: `.ok` with the search results.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's mapping, `TMDBError` from the
    ///   search.
    func searchMappingCandidates(_ input: Operations.searchMappingCandidates.Input) async throws -> Operations.searchMappingCandidates.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        _ = try await request.mappings.ownMapping(userID: user.requireID(), mappingID: id)
        let query = input.query.q.trimmingCharacters(in: .whitespaces)
        let results = query.count >= 2 ? try await request.tmdb.searchMulti(query) : []
        return .ok(.init(body: .json(results.prefix(10).map(Self.searchResult))))
    }

    /// Handles `GET /api/v1/imports/netflix/rows/{id}/options`: the episodes a row can be assigned to, i.e. those of
    /// the series its mapping points to.
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.ok` with the episode options.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's row, `APIError.notFound` when
    ///   the row's mapping does not point to a series.
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

    /// Handles `POST /api/v1/imports/netflix/rows/{id}/assign`: records the row as an imported watch of the given
    /// episode (`MappingService.assignRow`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with `episodeId`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID or missing body, `TrackingError.notFound` for an unknown or another user's row or an
    ///   unknown episode.
    func assignRow(_ input: Operations.assignRow.Input) async throws -> Operations.assignRow.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id), case let .json(body) = input.body,
              let episodeID = UUID(uuidString: body.episodeId) else { throw APIError.notFound }
        try await APIContext.request().mappings.assignRow(userID: user.requireID(), rowID: id, episodeID: episodeID)
        return .noContent(.init())
    }

    /// Handles `POST /api/v1/imports/netflix/rows/{id}/ignore`: ignores one unmatched row (`MappingService.ignoreRow`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's row.
    func ignoreRow(_ input: Operations.ignoreRow.Input) async throws -> Operations.ignoreRow.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().mappings.ignoreRow(userID: user.requireID(), rowID: id)
        return .noContent(.init())
    }

    /// Runs a mapping decision for the signed-in user's mapping, kicks the worker and returns the mapping.
    /// - Parameters:
    ///   - rawID: The mapping ID from the path.
    ///   - decide: The decision, called with the request, the user's ID and the mapping ID.
    /// - Returns: The mapping after the decision.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed ID, `TrackingError.notFound` for an unknown or another user's mapping, errors of `decide`.
    private func decideMapping(_ rawID: String, _ decide: (Request, UUID, UUID) async throws -> Void) async throws -> Components.Schemas.Mapping {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard let id = UUID(uuidString: rawID) else { throw APIError.notFound }
        try await decide(request, try user.requireID(), id)
        await request.application.matchingWorker.kick()
        let mapping = try await request.mappings.ownMapping(userID: user.requireID(), mappingID: id)
        return Self.mapping(mapping, titleName: try await mapping.$title.get(on: request.db)?.name)
    }

    /// Maps a Netflix mapping to the `Mapping` schema.
    /// - Parameters:
    ///   - mapping: The mapping (its title loaded when it has one).
    ///   - titleName: The title's name, overriding the loaded one.
    /// - Returns: The schema value.
    static func mapping(_ mapping: NetflixMapping, titleName: String?) -> Components.Schemas.Mapping {
        .init(id: mapping.id?.uuidString ?? "", netflixName: mapping.netflixName, kind: mapping.titleKind == .movie ? .movie : .tv,
              status: Components.Schemas.MappingStatus(rawValue: mapping.status) ?? .pending,
              title: mapping.$title.value.flatMap { $0 }.map { .init(tmdbId: $0.tmdbID, name: titleName ?? $0.name) })
    }

    /// Maps the import progress to the `ImportProgress` schema.
    /// - Parameter progress: The progress.
    /// - Returns: The schema value.
    static func progress(_ progress: ImportProgress) -> Components.Schemas.ImportProgress {
        .init(running: progress.isRunning, pendingRows: progress.pendingRows, waitingForReview: progress.waitingForReview,
              lastError: progress.lastError)
    }
}
