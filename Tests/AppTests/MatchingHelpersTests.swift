@testable import App
import Foundation
import Testing

@Suite("MatchingHelpers")
struct MatchingHelpersTests {
    func result(_ id: Int, _ name: String, original: String? = nil) -> TMDBSearchResult {
        TMDBSearchResult(id: id, kind: .tv, name: name, originalName: original, year: nil, posterPath: nil)
    }

    func candidates(_ seasons: [Int: [String]]) -> [EpisodeCandidate] {
        seasons.sorted { $0.key < $1.key }.flatMap { season, names in
            names.enumerated().map { EpisodeCandidate(id: UUID(), season: season, number: $0.offset + 1, name: $0.element) }
        }
    }

    func ids(_ pool: [EpisodeCandidate], _ keys: [String]) -> [UUID] {
        keys.map { key in pool.first { "\($0.season)x\($0.number)" == key }!.id }
    }

    @Test func normalizes() {
        #expect(normalizeTitle("Pokémon: Pika-Pikachu") == "pokemon pika pikachu")
        #expect(normalizeTitle("Extreme Maßnahmen (7)") == "extreme massnahmen")
        #expect(normalizeTitle("  Das, was du zurücklässt – Teil 1 ") == "das was du zurucklasst teil 1")
    }

    @Test func autoMatchUniqueExact() {
        let hit = autoMatch(candidate: "The Mentalist", in: [result(1, "The Mentalist"), result(2, "Mentalist: Ein Neuanfang")])
        #expect(hit?.id == 1)
    }

    @Test func autoMatchAmbiguousIsNil() {
        #expect(autoMatch(candidate: "Monster", in: [result(1, "Monster"), result(2, "Monster")]) == nil)
    }

    @Test func autoMatchOriginalName() {
        #expect(autoMatch(candidate: "Money Heist", in: [result(7, "Haus des Geldes", original: "Money Heist")])?.id == 7)
    }

    @Test func autoMatchAfterNormalizationOrNil() {
        let candidate = "DAHMER: Monster: Die Geschichte von Jeffrey Dahmer"
        #expect(autoMatch(candidate: candidate, in: [result(1, "DAHMER – Monster: Die Geschichte von Jeffrey Dahmer")])?.id == 1)
        #expect(autoMatch(candidate: candidate, in: [result(2, "Dahmer")]) == nil)
        #expect(autoMatch(candidate: "Dark", in: []) == nil)
    }

    @Test func episodeExact() {
        let pool = candidates([1: ["Pilot", "Rote Haare"]])
        #expect(matchEpisodes(title: "Rote Haare", season: 1, in: pool) == ids(pool, ["1x2"]))
    }

    @Test func episodeSuffixNumberIgnored() {
        let pool = candidates([7: ["Kampf", "Extreme Maßnahmen"]])
        #expect(matchEpisodes(title: "Extreme Maßnahmen (7)", season: 7, in: pool) == ids(pool, ["7x2"]))
    }

    @Test func episodeFolgeN() {
        let pool = candidates([1: ["Der Anfang", "Die Wahrheit", "Das Ende"]])
        #expect(matchEpisodes(title: "Folge 2", season: nil, in: pool) == ids(pool, ["1x2"]))
        let multi = candidates([1: ["A", "B"], 2: ["C", "D"]])
        #expect(matchEpisodes(title: "Folge 2", season: nil, in: multi).isEmpty)
        #expect(matchEpisodes(title: "Folge 2", season: 2, in: multi) == ids(multi, ["2x2"]))
    }

    @Test func episodeWithoutSeasonSearchesAll() {
        let pool = candidates([0: ["Pika-Pikachu Spezial"], 1: ["Ich wähle dich"], 2: ["Pika-Pikachu"]])
        #expect(matchEpisodes(title: "Pika-Pikachu", season: nil, in: pool) == ids(pool, ["2x1"]))
    }

    @Test func seasonRestrictsPool() {
        let pool = candidates([1: ["Pilot"], 2: ["Pilot 2"]])
        #expect(matchEpisodes(title: "Pilot 2", season: 1, in: pool).isEmpty)
    }

    @Test func doubleEpisode() {
        let pool = candidates([7: ["Im Angesicht", "Das, was du zurücklässt (1)", "Das, was du zurücklässt (2)"]])
        #expect(matchEpisodes(title: "Das, was du zurücklässt – Teil 1 und 2", season: 7, in: pool) == ids(pool, ["7x2", "7x3"]))
    }

    @Test func fuzzyTypo() {
        let pool = candidates([4: ["Allein in der Wildnis", "Die goldene Feder"]])
        #expect(matchEpisodes(title: "Allein in der Wildniss", season: 4, in: pool) == ids(pool, ["4x1"]))
    }

    @Test func fuzzyAmbiguousIsEmpty() {
        let pool = candidates([1: ["Der rote Faden (1)", "Der rote Faden (2)"]])
        #expect(matchEpisodes(title: "Der rote Faden", season: 1, in: pool).isEmpty)
    }

    @Test func noMatchIsEmpty() {
        let pool = candidates([1: ["Pilot", "Rote Haare"]])
        #expect(matchEpisodes(title: "Etwas völlig anderes", season: 1, in: pool).isEmpty)
    }
}

@Suite("FuzzyDigitGuard")
struct FuzzyDigitGuardTests {
    @Test func differentNumbersNeverFuzzyMatch() {
        let pool = [EpisodeCandidate(id: UUID(), season: 1, number: 1, name: "Die 7 Leben"),
                    EpisodeCandidate(id: UUID(), season: 1, number: 2, name: "Ein anderer Titel")]
        #expect(matchEpisodes(title: "Die 8 Leben", season: 1, in: pool).isEmpty)
    }

    @Test func sameNumbersStillFuzzyMatch() {
        let target = EpisodeCandidate(id: UUID(), season: 1, number: 1, name: "Die 7 Leben des Herrn")
        #expect(matchEpisodes(title: "Die 7 Leben des Hern", season: 1, in: [target]) == [target.id])
    }
}
