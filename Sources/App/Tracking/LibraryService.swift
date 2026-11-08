import Fluent
import Foundation
import Vapor

/// Titles the user watched, rated or hid (web „Bibliothek“ and `GET /v1/library`).
struct LibraryService {
    let db: any Database
    let watches: WatchService

    static let filters = ["all", "tv", "movie", "hidden"]
    static let sorts = ["recent", "rating", "name"]

    /// `filter`: all | tv | movie | hidden; `sort`: recent | rating | name (unknown values → defaults).
    func items(userID: UUID, filter rawFilter: String, sort rawSort: String) async throws -> [LibraryItem] {
        let filter = Self.filters.contains(rawFilter) ? rawFilter : "all"
        let sort = Self.sorts.contains(rawSort) ? rawSort : "recent"
        let watchList = try await watches.watchesQuery(userID: userID).all()
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).all()
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })
        var recency: [UUID: (String, Date)] = [:]
        for watch in watchList {
            let key = (watch.watchedOn ?? "", watch.createdAt ?? .distantPast)
            if let current = recency[watch.$title.id], current >= key { continue }
            recency[watch.$title.id] = key
        }
        let ratedIDs = entries.filter { $0.rating != nil || $0.hidden }.map(\.$title.id)
        let titleIDs = Array(Set(recency.keys).union(ratedIDs))
        let titles = titleIDs.isEmpty ? [] : try await Title.query(on: db).filter(\.$id ~~ titleIDs).all()

        var items = titles.map { title in
            LibraryItem(title: title, rating: entryByTitle[title.id!]?.rating, hidden: entryByTitle[title.id!]?.hidden ?? false)
        }.filter { item in
            switch filter {
            case "hidden": item.hidden
            case "tv": !item.hidden && item.title.titleKind == .tv
            case "movie": !item.hidden && item.title.titleKind == .movie
            default: !item.hidden
            }
        }
        switch sort {
        case "rating":
            items.sort { ($0.rating ?? 0, $1.title.name) > ($1.rating ?? 0, $0.title.name) }
        case "name":
            items.sort { $0.title.name.localizedCaseInsensitiveCompare($1.title.name) == .orderedAscending }
        default:
            items.sort { (recency[$0.title.id!] ?? ("", .distantPast)) > (recency[$1.title.id!] ?? ("", .distantPast)) }
        }
        return items
    }
}
