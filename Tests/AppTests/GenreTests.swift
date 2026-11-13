@testable import App
import Testing

@Suite("Genre")
struct GenreTests {
    @Test func splitsSeriesMixedGenres() {
        #expect(Genre.from(tmdbIDs: [10759]) == [.action, .adventure])
        #expect(Genre.from(tmdbIDs: [10765]) == [.scienceFiction, .fantasy])
        #expect(Genre.from(tmdbIDs: [10768]) == [.war, .politics])
    }

    @Test func dropsDuplicatesAndUnknownIDs() {
        #expect(Genre.from(tmdbIDs: [10759, 28, 99999]) == [.action, .adventure])
        #expect(Genre.from(tmdbIDs: [18, 80]) == [.drama, .crime])
        #expect(Genre.from(tmdbIDs: []) == [])
    }

    @Test func movieAndSeriesIDsShareKeys() {
        #expect(Genre.from(tmdbIDs: [878, 14]) == [.scienceFiction, .fantasy])
        #expect(Genre.from(tmdbIDs: [10752]) == [.war])
    }

    @Test func germanLabels() {
        #expect(Genre.scienceFiction.label == "Science-Fiction")
        #expect(Genre.comedy.label == "Komödie")
        #expect(Genre.sortedByLabel([.western, .adventure, .comedy, .action]).map(\.label) == ["Abenteuer", "Action", "Komödie", "Western"])
    }

    @Test func titleStoresGenreList() {
        let title = Title(tmdbID: 1, kind: .movie, name: "X")
        #expect(title.genreList == nil)
        title.genreList = [.action, .scienceFiction]
        #expect(title.genres == "action,science_fiction")
        #expect(title.genreList == [.action, .scienceFiction])
        title.genreList = []
        #expect(title.genres == "")
        #expect(title.genreList == [])
        title.genres = "drama,quatsch"
        #expect(title.genreList == [.drama])
        title.genreList = nil
        #expect(title.genres == nil)
    }
}
