@testable import App
import Foundation
import Testing

/// The sample from the design spec §1.
let standardImportSample = """
type,title,year,tmdb_id,imdb_id,season,episode,watched_on,service,rating,comment
movie,Dune,2021,438631,,,,2024-03-02,netflix,8,Im Kino besser
episode,Severance,2022,,tt11280740,1,3,2024-05-10,apple_tv,,
series,Severance,2022,,tt11280740,,,,,9,

"""

@Suite("StandardImportFormat")
struct StandardImportFormatTests {
    @Test func parsesAllRowTypes() throws {
        let file = try parseStandardImport(standardImportSample)
        #expect(file.rows.map(\.type) == [.movie, .episode, .series])
        #expect(file.skippedRows == 0)
        let movie = file.rows[0]
        #expect(movie.title == "Dune")
        #expect(movie.year == 2021)
        #expect(movie.tmdbID == 438631)
        #expect(movie.day == "2024-03-02")
        #expect(movie.service == .netflix)
        #expect(movie.rating == 8)
        #expect(movie.comment == "Im Kino besser")
        let episode = file.rows[1]
        #expect(episode.imdbID == "tt11280740")
        #expect(episode.season == 1)
        #expect(episode.episode == 3)
        #expect(episode.service == .appleTV)
        #expect(episode.rating == nil)
        #expect(episode.comment == nil)
        let series = file.rows[2]
        #expect(series.rating == 9)
        #expect(series.day == nil)
    }

    @Test func headerIsCaseInsensitiveAndMayBePreceded() throws {
        let file = try parseStandardImport("My export\n\n Type ;TITLE;Year\nMovie;Dune;2021\n")
        #expect(file.rows.count == 1)
        #expect(file.rows.first?.type == .movie)
        #expect(file.rows.first?.year == 2021)
    }

    @Test func excelSemicolonFile() throws {
        let file = try parseStandardImport("\u{FEFF}type;title;watched_on;rating\nmovie;Amélie;02.03.2024;7,5\n")
        #expect(file.rows.first?.title == "Amélie")
        #expect(file.rows.first?.day == "2024-03-02")
        #expect(file.rows.first?.rating == 8)
    }

    @Test func quotedFields() throws {
        let text = "type,title,comment\nseries,\"Love, Death & Robots\",\"Zeile 1\nZeile 2; mit \"\"Zitat\"\"\"\n"
        let row = try #require(try parseStandardImport(text).rows.first)
        #expect(row.title == "Love, Death & Robots")
        #expect(row.comment == "Zeile 1\nZeile 2; mit \"Zitat\"")
    }

    @Test func invalidRowsAreCounted() throws {
        let text = """
        type,title,year,tmdb_id,imdb_id,season,episode
        podcast,X
        movie,
        episode,Show,,,,1,

        episode,Show,,,,1,2

        """
        let file = try parseStandardImport(text)
        #expect(file.rows.count == 1)
        #expect(file.rows.first?.episode == 2)
        #expect(file.skippedRows == 3)
    }

    @Test func missingHeaderThrows() {
        #expect(throws: StandardImportError.noHeader) { try parseStandardImport("Filmname;Jahr\nDune;2021\n") }
    }

    @Test func dates() {
        for raw in ["2024-03-02", "2024-03-02T20:15:00Z", "2024-03-02 20:15", "02.03.2024", "2.3.2024", "3/2/24"] {
            #expect(importDay(raw) == "2024-03-02", "\(raw)")
        }
        for raw in ["2024-02-31", "gestern", ""] {
            #expect(importDay(raw) == nil, "\(raw)")
        }
    }

    @Test func ratings() {
        #expect(importRating("8") == 8)
        #expect(importRating("7.5") == 8)
        #expect(importRating("7,4") == 7)
        #expect(importRating("12") == 10)
        #expect(importRating("0.4") == 1)
        #expect(importRating("0") == nil)
        #expect(importRating("") == nil)
        #expect(importRating("gut") == nil)
    }

    @Test func services() {
        #expect(StreamingService(importValue: "prime_video") == .primeVideo)
        #expect(StreamingService(importValue: "Netflix") == .netflix)
        #expect(StreamingService(importValue: "Amazon Prime") == .primeVideo)
        #expect(StreamingService(importValue: "YouTube") == .other)
        #expect(StreamingService(importValue: "") == nil)
    }

    @Test func imdbIDsAreValidated() throws {
        let text = "type,title,imdb_id\nmovie,A,tt0123\nmovie,B,123\nmovie,C,https://imdb.com/title/tt1\n"
        #expect(try parseStandardImport(text).rows.map(\.imdbID) == ["tt0123", nil, nil])
    }

    @Test func groupsByIDThenTitle() throws {
        let text = """
        type,title,year,tmdb_id,imdb_id,season,episode,rating,comment
        movie,Dune,2021,438631,,,,7,A
        movie,„Dune“,2021,438631,,,,9,B
        movie,dune,2021,,,,,,
        episode,Severance,2022,,tt1,1,1,,
        episode,Severance,2022,,tt2,1,2,,
        episode,Severance,2022,,tt3,1,3,,
        series,Severance,2022,,tt11280740,,,,

        """
        let drafts = groupStandardImport(try parseStandardImport(text).rows)
        #expect(drafts.count == 4)
        #expect(drafts[0].kind == .movie)
        #expect(drafts[0].tmdbHint == 438631)
        #expect(drafts[0].watches.count == 2)
        #expect(drafts[0].rating == 9)
        #expect(drafts[0].comment == "A\n\nB")
        #expect(drafts[1].title == "dune")
        #expect(drafts[1].tmdbHint == nil)
        #expect(drafts[1].watches.count == 1)
        #expect(drafts[2].kind == .tv)
        #expect(drafts[2].imdbID == "tt1")
        #expect(drafts[2].watches.map(\.episode) == [1, 2, 3])
        #expect(drafts[3].kind == .tv)
        #expect(drafts[3].imdbID == "tt11280740")
        #expect(drafts[3].watches.isEmpty)
    }

    @Test func seriesRowAddsNoWatch() throws {
        let drafts = groupStandardImport(try parseStandardImport("type,title,rating\nseries,Dark,9\n").rows)
        #expect(drafts.count == 1)
        #expect(drafts[0].watches.isEmpty)
        #expect(drafts[0].rating == 9)
    }

    @Test func commentIsCappedAtMaxLength() throws {
        let long = String(repeating: "x", count: WatchService.maxCommentLength + 50)
        let drafts = groupStandardImport(try parseStandardImport("type,title,comment\nmovie,Dune,\(long)\n").rows)
        #expect(drafts.first?.comment?.count == WatchService.maxCommentLength)
    }
}
