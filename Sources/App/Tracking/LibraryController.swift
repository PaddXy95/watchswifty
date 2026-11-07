import Fluent
import Vapor

struct LibraryController {
    func register(on protected: any RoutesBuilder) {
        protected.get("library", use: library)
    }

    func library(req: Request) async throws -> HTMLResponse {
        let filter = ["all", "tv", "movie", "hidden"].contains((try? req.query.get(String.self, at: "filter")) ?? "")
            ? try req.query.get(String.self, at: "filter") : "all"
        let sort = ["recent", "rating", "name"].contains((try? req.query.get(String.self, at: "sort")) ?? "")
            ? try req.query.get(String.self, at: "sort") : "recent"
        let userID = try req.userID

        let watches = try await req.watches.watchesQuery(userID: userID).all()
        let entries = try await UserTitle.query(on: req.db).filter(\.$user.$id == userID).all()
        let entryByTitle = Dictionary(entries.map { ($0.$title.id, $0) }, uniquingKeysWith: { a, _ in a })
        var recency: [UUID: (String, Date)] = [:]
        for watch in watches {
            let key = (watch.watchedOn ?? "", watch.createdAt ?? .distantPast)
            if let current = recency[watch.$title.id], current >= key { continue }
            recency[watch.$title.id] = key
        }
        let ratedIDs = entries.filter { $0.rating != nil || $0.hidden }.map(\.$title.id)
        let titleIDs = Array(Set(recency.keys).union(ratedIDs))
        let titles = titleIDs.isEmpty ? [] : try await Title.query(on: req.db).filter(\.$id ~~ titleIDs).all()

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
        return HTMLResponse(LibraryPage(navContext: try req.nav(.library), items: items, filter: filter, sort: sort))
    }
}
