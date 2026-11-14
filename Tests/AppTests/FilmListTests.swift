@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Synthetic list in the layout of the user's Numbers export (group rows, WAHR/FALSCH, German dates).
let filmListSample = """
;Filmname;Erscheinungsjahr;Genre;Datum;Mit Anna;Mit Ben;Streamingdienst;Übeltäter;Bewertung;Detail;Bemerkung
Bewertung:;;;;;;;;;;Mittelwert:;
5 ★;;;;;;;;;;95,0;
;Sternenreise;2014;Sci-Fi;Mo., 1. Jan. 2024;WAHR;FALSCH;Netflix;Pat;5;99;
;Inselrätsel;2010;Thriller;Mo., 1. Jan. 2024;FALSCH;FALSCH;Netflix;Pat;5;98;
;Inselrätsel;2010;Thriller;So., 15. Juni 2025;WAHR;WAHR;Amazon Prime;Anna;4,5;85;"Zweites Mal; mit Popcorn"
;Ohne Datum;2026;Fantasy;;FALSCH;FALSCH;;;5;98;
4,5 ★;;;;;;;;;;84,6;
;Nachtfahrt;2025;Drama;Keine Ahnung wann;WAHR;WAHR;Youtube;;4,5;;Ganz okay

"""

@Suite("FilmListParsing")
struct FilmListParsingTests {
    @Test func parsesGermanDates() {
        #expect(germanDay("Mo., 1. Jan. 2024") == "2024-01-01")
        #expect(germanDay("So., 15. Juni 2025") == "2025-06-15")
        #expect(germanDay("Fr., 18. Sept. 2026") == "2026-09-18")
        #expect(germanDay("Do., 6. März 2025") == "2025-03-06")
        #expect(germanDay("Sa., 26. Apr. 2025") == "2025-04-26")
        #expect(germanDay("Mi., 4. Dez. 2024") == "2024-12-04")
        #expect(germanDay("Do., 24. Juli 2025") == "2025-07-24")
        #expect(germanDay("01.02.2025") == "2025-02-01")
        #expect(germanDay("2025-02-01") == "2025-02-01")
        #expect(germanDay("31. Feb. 2025") == nil)
        #expect(germanDay("Keine Ahnung wann") == nil)
        #expect(germanDay("") == nil)
    }

    @Test func ratingFromDetail() {
        #expect(filmRating(detail: "99", stars: "5") == 10)
        #expect(filmRating(detail: "95", stars: "5") == 10)
        #expect(filmRating(detail: "91", stars: "5") == 9)
        #expect(filmRating(detail: "85", stars: "4,5") == 9)
        #expect(filmRating(detail: "75", stars: "4") == 8)
        #expect(filmRating(detail: "4", stars: "0,5") == 1)   // the app knows 1–10 only
        #expect(filmRating(detail: "", stars: "4,5") == 9)
        #expect(filmRating(detail: "", stars: "0,5") == 1)
        #expect(filmRating(detail: "", stars: "") == nil)
        #expect(filmRating(detail: "abc", stars: "") == nil)
    }

    /// Huge numbers are clamped and non-finite ones ignored instead of trapping in `Int(Double)` (security audit F02).
    @Test func ratingSurvivesExtremeNumbers() {
        #expect(filmRating(detail: "1e300", stars: "") == 10)
        #expect(filmRating(detail: "-1e300", stars: "") == 1)
        #expect(filmRating(detail: "", stars: "1e300") == 10)
        #expect(filmRating(detail: "nan", stars: "") == nil)
        #expect(filmRating(detail: "inf", stars: "") == nil)
        #expect(filmRating(detail: "nan", stars: "4,5") == 9)
    }

    @Test func serviceLabels() {
        #expect(StreamingService(label: "Netflix") == .netflix)
        #expect(StreamingService(label: "Amazon Prime") == .primeVideo)
        #expect(StreamingService(label: "Disney+") == .disneyPlus)
        #expect(StreamingService(label: "AppleTV+") == .appleTV)
        #expect(StreamingService(label: "WowTV") == .wow)
        #expect(StreamingService(label: "HBO Max") == .hboMax)
        #expect(StreamingService(label: "Paramount+") == .paramountPlus)
        #expect(StreamingService(label: "Gekauft") == .purchased)
        #expect(StreamingService(label: "Kino") == .cinema)
        #expect(StreamingService(label: "Youtube") == .other)
        #expect(StreamingService(label: "Geliehen") == .other)
        #expect(StreamingService(label: " ") == nil)
    }

    @Test func parsesFilmListSkippingGroupRows() throws {
        let rows = try parseFilmList(filmListSample)
        #expect(rows.map(\.title) == ["Sternenreise", "Inselrätsel", "Inselrätsel", "Ohne Datum", "Nachtfahrt"])
        #expect(rows[0] == FilmListRow(title: "Sternenreise", year: 2014, day: "2024-01-01", service: .netflix, rating: 10,
                                       companions: ["Anna"], culprit: "Pat", remark: nil))
        #expect(rows[2].companions == ["Anna", "Ben"])
        #expect(rows[2].remark == "Zweites Mal; mit Popcorn")
        #expect(rows[2].service == .primeVideo)
        #expect(rows[3].day == nil)
        #expect(rows[3].service == nil)
        #expect(rows[3].culprit == nil)
        #expect(rows[4].service == .other)
        #expect(rows[4].rating == 9)   // stars × 2 when „Detail“ is empty
        #expect(throws: FilmListError.notFilmList) { try parseFilmList("Title,Date\nX,1/1/24\n") }
    }

    @Test func groupsRepeatedFilmsWithComments() throws {
        let drafts = groupFilmList(try parseFilmList(filmListSample))
        #expect(drafts.map(\.title) == ["Sternenreise", "Inselrätsel", "Ohne Datum", "Nachtfahrt"])
        #expect(drafts[0].watches == [FilmWatch(day: "2024-01-01", service: .netflix)])
        #expect(drafts[0].rating == 10)
        #expect(drafts[0].comment == "Mit Anna\nÜbeltäter: Pat")
        #expect(drafts[1].watches == [FilmWatch(day: "2024-01-01", service: .netflix), FilmWatch(day: "2025-06-15", service: .primeVideo)])
        #expect(drafts[1].rating == 9)   // from the most recent viewing
        #expect(drafts[1].comment == "01.01.2024: Übeltäter: Pat\n15.06.2025: Mit Anna und Ben · Übeltäter: Anna · Zweites Mal; mit Popcorn")
        #expect(drafts[2].watches == [FilmWatch(day: nil, service: nil)])
        #expect(drafts[2].comment == nil)
        #expect(drafts[3].comment == "Mit Anna und Ben\nGanz okay")
    }
}

@Suite("FilmListMatching")
struct FilmListMatchingTests {
    func movie(_ id: Int, _ name: String, _ year: Int?) -> TMDBSearchResult {
        TMDBSearchResult(id: id, kind: .movie, name: name, originalName: nil, year: year, posterPath: nil)
    }

    @Test func choosesUniqueYearMatch() {
        let results = [movie(1, "Die Mumie", 2017), movie(2, "Die Mumie", 1999), movie(3, "Die Mumie", 1932)]
        #expect(chooseFilm(query: "Die Mumie", year: 1999, results: results) == .match(movie(2, "Die Mumie", 1999)))
        let single = [movie(4, "Inglourious Basterds", 2009), movie(5, "Basterds – Doku", 2015)]
        #expect(chooseFilm(query: "Inglorious Bastard", year: 2009, results: single) == .match(movie(4, "Inglourious Basterds", 2009)))
        #expect(chooseFilm(query: "Sternenreise", year: nil, results: [movie(6, "Sternenreise", 2014), movie(7, "Sternenreise 2", 2018)])
                == .match(movie(6, "Sternenreise", 2014)))
    }

    @Test func ambiguousGoesToReview() {
        let two = [movie(1, "Fluch der Karibik – Am Ende der Welt", 2007), movie(2, "Fluch der Karibik – Making-of", 2007)]
        #expect(chooseFilm(query: "Pirates of the Caribbean 3", year: 2007, results: two) == .review(two))
        #expect(chooseFilm(query: "X", year: 2020, results: [movie(3, "X", 1990)]) == .review([movie(3, "X", 1990)]))
        #expect(chooseFilm(query: "Nichts", year: 2020, results: []) == .notFound)
    }

    /// A stored out-of-range year must not trap in the year distance (security audit F03).
    @Test(arguments: [Int.min, Int.max])
    func extremeYearGoesToReview(year: Int) {
        let matrix = [movie(1, "Matrix", 1999)]
        #expect(chooseFilm(query: "Matrix", year: year, results: matrix) == .review(matrix))
    }

    /// Implausible years are dropped when the list is read, so they are never stored (security audit F03).
    @Test func parserDropsImplausibleYears() throws {
        let rows = try parseFilmList("Filmname;Erscheinungsjahr\nMatrix;-9223372036854775808\nUhrwerk Orange;1971\nZukunft;99999\n")
        #expect(rows.map(\.year) == [nil, 1971, nil])
    }
}

@Suite("FilmListImport")
struct FilmListImportTests {
    static func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Sternenreise", originalName: nil, year: 2014, posterPath: nil, runtime: 169))
        tmdb.addMovie(TMDBMovie(id: 604, name: "Inselrätsel", originalName: nil, year: 2010, posterPath: nil, runtime: 138))
        tmdb.setSearch("movie", "Sternenreise", [TMDBSearchResult(id: 603, kind: .movie, name: "Sternenreise", originalName: nil, year: 2014, posterPath: nil)])
        tmdb.setSearch("movie", "Inselrätsel", [
            TMDBSearchResult(id: 604, kind: .movie, name: "Das Inselrätsel", originalName: nil, year: 2010, posterPath: nil),
            TMDBSearchResult(id: 605, kind: .movie, name: "Inselrätsel – Die Doku", originalName: nil, year: 2011, posterPath: nil),
        ])
        tmdb.setSearch("movie", "Insel", [TMDBSearchResult(id: 604, kind: .movie, name: "Das Inselrätsel", originalName: nil, year: 2010, posterPath: nil)])
        return tmdb
    }

    func entries(_ app: Application, _ user: User) async throws -> [FilmListEntry] {
        try await FilmListEntry.query(on: app.db).filter(\.$user.$id == user.requireID()).sort(\.$position).all()
    }

    @Test func recordCreatesWatchesRatingComment() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let service = FilmListService(db: app.db)
            try await service.replace(userID: user.requireID(), drafts: groupFilmList(try parseFilmList(filmListSample)))
            let inselEntry = try await entries(app, user)[1]
            let importer = FilmListImporter(db: app.db, tmdb: tmdb, today: "2026-11-07")
            try await importer.record(inselEntry, tmdbID: 604)

            let title = try #require(try await Title.query(on: app.db).filter(\.$tmdbID == 604).first())
            #expect(title.runtime == 138)
            let watches = try await Watch.query(on: app.db).filter(\.$title.$id == title.requireID()).sort(\.$watchedOn).all()
            #expect(watches.map(\.watchedOn) == ["2024-01-01", "2025-06-15"])
            #expect(watches.map(\.streamingService) == [.netflix, .primeVideo])
            let entry = try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: title.requireID())
            #expect(entry.rating == 9)
            #expect(entry.comment?.hasPrefix("01.01.2024: Übeltäter: Pat") == true)
            #expect(try await FilmListEntry.find(inselEntry.requireID(), on: app.db)?.status == FilmListStatus.imported.rawValue)
        }
    }

    @Test func reimportDoesNotDuplicate() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let service = FilmListService(db: app.db)
            let importer = FilmListImporter(db: app.db, tmdb: tmdb, today: "2026-11-07")
            let drafts = groupFilmList(try parseFilmList(filmListSample))
            let movie = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .movie, tmdbID: 603)
            // Already seen one day later (e.g. from the Netflix import) and commented by hand.
            try await Watch(userID: user.requireID(), titleID: movie.requireID(), episodeID: nil, watchedOn: "2024-01-02",
                            service: .netflix, origin: .import).save(on: app.db)
            try await WatchService(db: app.db).setComment(userID: user.requireID(), titleID: movie.requireID(), comment: "Alt")

            for _ in 1...2 {
                try await service.replace(userID: user.requireID(), drafts: drafts)
                try await importer.record(try await entries(app, user)[0], tmdbID: 603)
            }
            #expect(try await Watch.query(on: app.db).filter(\.$title.$id == movie.requireID()).count() == 1)
            let comment = try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: movie.requireID()).comment
            #expect(comment == "Alt\n\nMit Anna\nÜbeltäter: Pat")
        }
    }

    @Test func workerResolvesPendingEntries() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            try await FilmListService(db: app.db).replace(userID: user.requireID(), drafts: groupFilmList(try parseFilmList(filmListSample)))
            _ = try await app.filmListWorker.processAll()
            let statuses = try await entries(app, user).map(\.status)
            #expect(statuses == ["imported", "review", "not_found", "not_found"])
            let review = try await entries(app, user)[1]
            #expect(review.candidateList.map(\.id) == [604, 605])
        }
    }

    @Test func workerWithoutTokenKeepsEntriesPending() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let user = try await createUser(app, "pat", tmdbToken: nil)
            try await FilmListService(db: app.db).replace(userID: user.requireID(), drafts: groupFilmList(try parseFilmList(filmListSample)))
            _ = try await app.filmListWorker.processAll()
            let list = try await entries(app, user)
            #expect(list.allSatisfy { $0.status == "pending" })
            #expect(list.first?.error == TMDBError.missingToken.description)
        }
    }

    @Test func uploadAndReviewFlow() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                #expect(res.body.string.contains(#"href="/import/films""#))
            }
            try await app.testing().test(.POST, "/import/films", headers: headers, beforeRequest: { req in
                try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: filmListSample), filename: "Filme.csv")), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("4 Filme übernommen"))
            })
            _ = try await app.filmListWorker.processAll()
            try await app.testing().test(.GET, "/import/films", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains("Das Inselrätsel (2010)"))
                #expect(body.contains(#"href="https://www.themoviedb.org/movie/604""#))
                #expect(body.contains(">Übernehmen</button>"))
                #expect(body.contains("Nachtfahrt"))
            }
            let list = try await entries(app, user)
            try await app.testing().test(.POST, "/import/films/\(try list[1].requireID())/accept", headers: headers, beforeRequest: { req in
                try req.content.encode(["tmdbID": 604], as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            #expect(try await FilmListEntry.find(list[1].requireID(), on: app.db)?.status == "imported")

            try await app.testing().test(.POST, "/import/films/\(try list[3].requireID())/search", headers: headers, beforeRequest: { req in
                try req.content.encode(["q": "Insel"], as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let searched = try #require(try await FilmListEntry.find(list[3].requireID(), on: app.db))
            #expect(searched.status == "review")   // a manual search always lets the user pick
            #expect(searched.candidateList.map(\.id) == [604])

            try await app.testing().test(.POST, "/import/films/\(try list[2].requireID())/skip", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await FilmListEntry.find(list[2].requireID(), on: app.db)?.status == "skipped")
        }
    }

    @Test func entriesArePrivate() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let owner = try await createUser(app, "pat")
            _ = try await createUser(app, "other")
            try await FilmListService(db: app.db).replace(userID: owner.requireID(), drafts: groupFilmList(try parseFilmList(filmListSample)))
            let id = try await entries(app, owner)[0].requireID()
            let headers = try await login(app, "other")
            try await app.testing().test(.POST, "/import/films/\(id)/skip", headers: headers) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
