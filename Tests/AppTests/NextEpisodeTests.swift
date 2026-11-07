@testable import App
import Foundation
import Testing

@Suite("NextEpisode")
struct NextEpisodeTests {
    static let today = "2026-11-07"

    /// Builds episodes for `seasons` (season → count), aired 2020-01-01 unless listed.
    func make(_ seasons: [Int: Int], unaired: Set<String> = [], noAirDate: Set<String> = []) -> [EpisodeInfo] {
        seasons.sorted { $0.key < $1.key }.flatMap { season, count in
            (1...count).map { n in
                let key = "\(season)x\(n)"
                return EpisodeInfo(id: UUID(), season: season, number: n, name: key,
                                   airDate: noAirDate.contains(key) ? nil : (unaired.contains(key) ? "2999-01-01" : "2020-01-01"))
            }
        }
    }

    func ids(_ eps: [EpisodeInfo], _ keys: [String]) -> Set<UUID> {
        Set(eps.filter { keys.contains("\($0.season)x\($0.number)") }.map(\.id))
    }

    @Test func basicNext() {
        let eps = make([1: 4])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["1x1", "1x2"]), today: Self.today)?.name == "1x3")
    }

    @Test func gapsBeforeHighestIgnored() {
        let eps = make([1: 4])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["1x1", "1x3"]), today: Self.today)?.name == "1x4")
    }

    @Test func specialsIgnored() {
        let eps = make([0: 5, 1: 2])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["0x5"]), today: Self.today) == nil)
    }

    @Test func crossesSeason() {
        let eps = make([1: 2, 2: 2])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["1x1", "1x2"]), today: Self.today)?.name == "2x1")
    }

    @Test func unairedAfterHighestGivesNil() {
        let eps = make([1: 3], unaired: ["1x3"])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["1x2"]), today: Self.today) == nil)
    }

    @Test func nilAirDateCountsAsUnaired() {
        let eps = make([1: 3], noAirDate: ["1x3"])
        #expect(nextEpisode(in: eps, watched: ids(eps, ["1x2"]), today: Self.today) == nil)
    }

    @Test func nothingWatchedGivesNil() {
        #expect(nextEpisode(in: make([1: 3]), watched: [], today: Self.today) == nil)
    }

    @Test func remainingCountsAiredUnwatchedFromNext() {
        let eps = make([4: 24], unaired: ["4x24"])
        let watched = ids(eps, (1...14).map { "4x\($0)" })
        let next = try! #require(nextEpisode(in: eps, watched: watched, today: Self.today))
        #expect(next.name == "4x15")
        #expect(remainingAiredCount(in: eps, from: next, watched: watched, today: Self.today) == 9)
    }
}
