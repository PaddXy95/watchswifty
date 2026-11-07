@testable import App
import Testing

@Suite("NetflixTitleParser")
struct NetflixTitleParserTests {
    static let cases: [(String, ParsedNetflixTitle)] = [
        ("The Mentalist: Staffel 4: Die Aura des Todes", .episode(show: "The Mentalist", season: 4, episodeTitle: "Die Aura des Todes")),
        ("Star Trek: Deep Space Nine: Staffel 7: Extreme Maßnahmen (7)", .episode(show: "Star Trek: Deep Space Nine", season: 7, episodeTitle: "Extreme Maßnahmen (7)")),
        ("Star Trek: Deep Space Nine: Staffel 3: Die Suche: Teil 1", .episode(show: "Star Trek: Deep Space Nine", season: 3, episodeTitle: "Die Suche: Teil 1")),
        ("Haus des Geldes: Teil 1: Folge 6", .episode(show: "Haus des Geldes", season: 1, episodeTitle: "Folge 6")),
        ("Doppelhaushälfte: Season 3: Der Traum ist aus", .episode(show: "Doppelhaushälfte", season: 3, episodeTitle: "Der Traum ist aus")),
        ("Leben auf unserem Planeten: Kapitel 1: Die Regeln des Lebens", .episode(show: "Leben auf unserem Planeten", season: 1, episodeTitle: "Die Regeln des Lebens")),
        ("Ted: Ted – Staffel 1: Die letzte Jungfrau", .episode(show: "Ted", season: 1, episodeTitle: "Die letzte Jungfrau")),
        ("HIS & HERS: Miniserie: Folge 6", .episode(show: "HIS & HERS", season: nil, episodeTitle: "Folge 6")),
        ("DAHMER: Monster: Die Geschichte von Jeffrey Dahmer: Verstummt", .episode(show: "DAHMER: Monster: Die Geschichte von Jeffrey Dahmer", season: nil, episodeTitle: "Verstummt")),
        ("Pokémon: Pika-Pikachu", .episode(show: "Pokémon", season: nil, episodeTitle: "Pika-Pikachu")),
        ("Keine Fremde: Folge 2", .episode(show: "Keine Fremde", season: nil, episodeTitle: "Folge 2")),
        ("Das fünfte Element", .movie(title: "Das fünfte Element")),
        ("Twilight – Biss zum Morgengrauen", .movie(title: "Twilight – Biss zum Morgengrauen")),
    ]

    @Test(arguments: cases)
    func parses(raw: String, expected: ParsedNetflixTitle) {
        #expect(parseNetflixTitle(raw) == expected)
    }

    @Test func markerAsLastSegmentIsNotASplit() {
        // "Teil 1" at the end belongs to the episode title, there is nothing after it.
        #expect(parseNetflixTitle("Film: Teil 1") == .episode(show: "Film", season: nil, episodeTitle: "Teil 1"))
    }
}
