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

    /// Real titles stay far below the limit; longer ones are cut so matching stays cheap (security audit F05).
    @Test func overlongTitlesAreCut() throws {
        let rows = try parseNetflixCSV("Title,Date\n" + String(repeating: "x", count: 600) + ",1/1/20").rows
        #expect(rows.first?.title == String(repeating: "x", count: maxImportTitleLength))
        #expect(rows.first?.fingerprint == "2020-01-01#0#" + String(repeating: "x", count: maxImportTitleLength))
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
        #expect(throws: NetflixCSVError.invalidDate(line: 2, value: "Nov 7, 2026")) {
            try parseNetflixCSV("Title,Date\n\"A\",\"Nov 7, 2026\"\n")
        }
        #expect(throws: NetflixCSVError.invalidDate(line: 3, value: "13/1/24")) {
            try parseNetflixCSV("Title,Date\n\"A\",\"1/1/24\"\n\"B\",\"13/1/24\"\n")
        }
    }
}

@Suite("NetflixCSVExcel")
struct NetflixCSVExcelTests {
    @Test func germanExcelSemicolonFile() throws {
        let text = "Title;Date\r\n\"The Mentalist: Staffel 4: Die Aura des Todes\";07.11.2026\r\nDas fünfte Element;24.12.2020\r\n"
        let result = try parseNetflixCSV(text)
        #expect(result.rows.map(\.title) == ["The Mentalist: Staffel 4: Die Aura des Todes", "Das fünfte Element"])
        #expect(result.rows.map(\.day) == ["2026-11-07", "2020-12-24"])
    }

    @Test func semicolonFileHasSameFingerprintsAsOriginal() throws {
        let original = try parseNetflixCSV("Title,Date\n\"A: Staffel 1: B\",\"11/7/26\"\n")
        let excel = try parseNetflixCSV("Title;Date\nA: Staffel 1: B;07.11.2026\n")
        #expect(original.rows.map(\.fingerprint) == excel.rows.map(\.fingerprint))
    }

    @Test func otherDateFormats() {
        #expect(netflixDay("7.11.2026") == "2026-11-07")
        #expect(netflixDay("07.11.26") == "2026-11-07")
        #expect(netflixDay("2026-11-07") == "2026-11-07")
        #expect(netflixDay("11/7/2026") == "2026-11-07")
        #expect(netflixDay("31.02.2026") == nil)
    }
}
