@testable import App
import Foundation
import Testing

@Suite("NotificationTexts")
struct NotificationTextsTests {
    static let today = "2026-11-07"

    func item(_ series: String, tmdbID: Int = 1399, _ season: Int, _ number: Int, name: String = "Folge",
              airDate: String?, _ kinds: Set<NoticeKind>) -> DueNotice {
        DueNotice(episodeID: UUID(), tmdbEpisodeID: season * 100 + number, seriesTMDBID: tmdbID, seriesName: series, season: season,
                  number: number, name: name, airDate: airDate, kinds: kinds)
    }

    @Test func subjectCountsByHeadline() {
        let items = [item("A", 1, 1, airDate: Self.today, [.today]), item("A", 1, 2, airDate: Self.today, [.today, .announced])]
            + (3...7).map { item("A", 1, $0, airDate: nil, [.announced]) }
        #expect(NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: nil).subject
                == "WatchSwifty: 2 Folgen heute, 5 neu angekündigt")
        #expect(NotificationTexts.digest(username: "pat", items: [item("A", 1, 1, airDate: "2026-11-09", [.soon])], today: Self.today,
                                         baseURL: nil).subject == "WatchSwifty: 1 Folge in den nächsten Tagen")
        #expect(NotificationTexts.digest(username: "pat", items: [item("A", 1, 1, airDate: Self.today, [.today])], today: Self.today,
                                         baseURL: nil).subject == "WatchSwifty: 1 Folge heute")
    }

    @Test func bodyGroupsBySeriesAndSection() {
        let items = [
            item("the Expanse", tmdbID: 2, 3, 1, name: "Neu", airDate: nil, [.announced]),
            item("the Expanse", tmdbID: 2, 2, 4, name: "Bald", airDate: "2026-11-10", [.soon]),
            item("the Expanse", tmdbID: 2, 2, 3, name: "Jetzt", airDate: Self.today, [.today]),
            item("Andor", tmdbID: 1, 1, 1, name: "Eins", airDate: Self.today, [.today]),
        ]
        let body = NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: nil).body
        #expect(body == """
            Hallo pat,

            es gibt Neues zu deinen beobachteten Serien:

            Andor
              Heute:
              S01E01 „Eins“

            the Expanse
              Heute:
              S02E03 „Jetzt“
              In den nächsten Tagen:
              S02E04 „Bald“ – Di., 10.11.2026 (in 3 Tagen)
              Neu angekündigt:
              S03E01 „Neu“ – Termin noch offen

            Die Termine sind die von TMDB – bei US-Serien oft einen Tag vor der Verfügbarkeit hier.
            Abschalten unter „Konto → Benachrichtigungen“.

            Viele Grüße
            WatchSwifty
            """)
    }

    @Test func dateSuffixes() {
        let items = [item("A", 1, 1, airDate: "2026-11-08", [.soon]), item("A", 1, 2, airDate: "2026-11-10", [.soon]),
                     item("A", 1, 3, airDate: nil, [.announced]), item("A", 1, 4, airDate: "2026-12-24", [.announced])]
        let body = NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: nil).body
        #expect(body.contains("S01E01 „Folge“ – So., 08.11.2026 (morgen)"))
        #expect(body.contains("S01E02 „Folge“ – Di., 10.11.2026 (in 3 Tagen)"))
        #expect(body.contains("S01E03 „Folge“ – Termin noch offen"))
        #expect(body.contains("S01E04 „Folge“ – Do., 24.12.2026\n"))
    }

    @Test func linkOnlyWithBaseURL() {
        let items = [item("A", tmdbID: 1399, 1, 1, airDate: Self.today, [.today])]
        #expect(NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: "https://watch.example.lan").body
            .contains("  S01E01 „Folge“\n  https://watch.example.lan/tv/1399\n"))
        #expect(!NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: nil).body.contains("http"))
    }

    @Test func namesStayOnOneLine() {
        let items = [item("Serie\nmit Umbruch", 1, 1, name: "A\nB", airDate: Self.today, [.today])]
        let body = NotificationTexts.digest(username: "pat", items: items, today: Self.today, baseURL: nil).body
        #expect(body.contains("„A B“"))
        #expect(body.contains("\nSerie mit Umbruch\n"))
    }
}
