@testable import App
import Foundation
import Testing

func fixtureText(_ name: String = "netflix-sample") throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("NetflixCSV")
struct NetflixCSVTests {
    @Test func parsesFixture() throws {
        let result = try parseNetflixCSV(try fixtureText())
        #expect(result.rows.count == 19)
        #expect(result.skippedBlank == 2)
        #expect(result.rows.first?.title == "The Mentalist: Staffel 4: Die Aura des Todes")
        #expect(result.rows.first?.day == "2026-11-07")
        #expect(result.rows.first { $0.title == "Pokémon: Pika-Pikachu" }?.day == "2015-10-04")
        #expect(result.rows.first { $0.title == "Das fünfte Element" }?.day == "2020-12-24")
    }

    @Test func duplicateSameDayGetsOccurrence() throws {
        let pilots = try parseNetflixCSV(try fixtureText()).rows.filter { $0.title == "The Mentalist: Staffel 1: Pilot" }
        #expect(pilots.map(\.fingerprint) == ["2020-01-01#0#The Mentalist: Staffel 1: Pilot", "2020-01-01#1#The Mentalist: Staffel 1: Pilot"])
    }

    @Test func commaInsideQuotes() throws {
        let rows = try parseNetflixCSV(try fixtureText()).rows
        #expect(rows.contains { $0.title == "Star Trek: Deep Space Nine: Staffel 7: Das, was du zurücklässt – Teil 1 und 2" })
    }

    @Test func bomAndCRLF() throws {
        let original = try fixtureText()
        let excel = "\u{FEFF}" + original.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try parseNetflixCSV(excel) == parseNetflixCSV(original))
    }

    @Test func escapedQuotes() throws {
        let result = try parseNetflixCSV("Title,Date\n\"Der \"\"Eine\"\": Film\",\"1/2/24\"\n")
        #expect(result.rows.map(\.title) == [#"Der "Eine": Film"#])
    }

    @Test func rejectsOtherCSV() {
        #expect(throws: NetflixCSVError.notNetflixHistory) {
            try parseNetflixCSV("Profile Name,Start Time,Duration\nPat,2026-01-01 10:00:00,00:20:00\n")
        }
        #expect(throws: NetflixCSVError.notNetflixHistory) { try parseNetflixCSV("") }
    }

    @Test func invalidDateReportsLine() {
        #expect(throws: NetflixCSVError.invalidDate(line: 2, value: "2026-11-07")) {
            try parseNetflixCSV("Title,Date\n\"A\",\"2026-11-07\"\n")
        }
        #expect(throws: NetflixCSVError.invalidDate(line: 3, value: "13/1/24")) {
            try parseNetflixCSV("Title,Date\n\"A\",\"1/1/24\"\n\"B\",\"13/1/24\"\n")
        }
    }
}
