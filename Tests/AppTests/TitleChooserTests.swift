@testable import App
import Testing

@Suite("TitleChooser")
struct TitleChooserTests {
    func movie(_ id: Int, _ name: String, _ year: Int?, original: String? = nil) -> TMDBSearchResult {
        TMDBSearchResult(id: id, kind: .movie, name: name, originalName: original, year: year, posterPath: nil)
    }

    func series(_ id: Int, _ name: String, _ year: Int?) -> TMDBSearchResult {
        TMDBSearchResult(id: id, kind: .tv, name: name, originalName: nil, year: year, posterPath: nil)
    }

    @Test func choosesUniqueYearMatch() {
        let results = [movie(1, "Die Mumie", 2017), movie(2, "Die Mumie", 1999), movie(3, "Die Mumie", 1932)]
        #expect(chooseTitle(query: "Die Mumie", year: 1999, results: results) == .match(movie(2, "Die Mumie", 1999)))
        let single = [movie(4, "Inglourious Basterds", 2009), movie(5, "Basterds – Doku", 2015)]
        #expect(chooseTitle(query: "Inglorious Bastard", year: 2009, results: single) == .match(movie(4, "Inglourious Basterds", 2009)))
        #expect(chooseTitle(query: "Sternenreise", year: nil, results: [movie(6, "Sternenreise", 2014), movie(7, "Sternenreise 2", 2018)])
                == .match(movie(6, "Sternenreise", 2014)))
    }

    @Test func ambiguousGoesToReview() {
        let two = [movie(1, "Fluch der Karibik – Am Ende der Welt", 2007), movie(2, "Fluch der Karibik – Making-of", 2007)]
        #expect(chooseTitle(query: "Pirates of the Caribbean 3", year: 2007, results: two) == .review(two))
        #expect(chooseTitle(query: "X", year: 2020, results: [movie(3, "X", 1990)]) == .review([movie(3, "X", 1990)]))
        #expect(chooseTitle(query: "Nichts", year: 2020, results: []) == .notFound)
    }

    @Test func choosesSeriesByFirstAirYear() {
        let results = [series(70523, "Dark", 2017), series(1, "Dark", 2005)]
        #expect(chooseTitle(query: "Dark", year: 2017, results: results) == .match(series(70523, "Dark", 2017)))
    }

    @Test func plausibility() {
        let dune = movie(438631, "Dune", 2021)
        #expect(plausibleIDMatch(title: "Dune", year: 2021, found: dune))
        #expect(plausibleIDMatch(title: "Der Wüstenplanet", year: 2021, found: dune))   // year fits
        #expect(plausibleIDMatch(title: "Dune", year: 1984, found: dune))               // title fits
        #expect(plausibleIDMatch(title: "Der Wüstenplanet", year: 2022, found: dune))   // ±1 year
        #expect(plausibleIDMatch(title: "Dünë", year: nil, found: movie(1, "X", 2000, original: "Dune")))
        #expect(!plausibleIDMatch(title: "Severance", year: 2022 + 5, found: dune))
        #expect(!plausibleIDMatch(title: "Severance", year: 2024, found: dune))
        #expect(plausibleIDMatch(title: "Foo", year: nil, found: dune))
    }

    /// Stored or crafted out-of-range years must not trap in the year distance (security audit F03).
    @Test(arguments: [Int.min, Int.max])
    func extremeYearsDoNotTrap(year: Int) {
        let matrix = [movie(1, "Matrix", 1999)]
        #expect(chooseTitle(query: "Matrix", year: year, results: matrix) == .review(matrix))
        #expect(!plausibleIDMatch(title: "Other", year: year, found: movie(1, "Matrix", 1999)))
        #expect(!plausibleIDMatch(title: "Other", year: 2000, found: movie(1, "Matrix", Int.min)))
    }
}
