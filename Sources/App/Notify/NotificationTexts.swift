import Foundation

/// Notifications a user gets by mail or webhook (plain text, German).
enum NotificationTexts {
    static func test(username: String) -> NotificationMessage {
        NotificationMessage(subject: "WatchSwifty: Testnachricht", body: """
            Hallo \(username),

            diese Testnachricht zeigt, dass deine Benachrichtigungen ankommen.

            Viele Grüße
            WatchSwifty
            """)
    }

    static func newDevice(username: String, device: String, at date: Date, link: String?) -> NotificationMessage {
        // The app chooses the device name: kept on one line, so it cannot add text of its own to the message.
        let name = oneLine(device)
        let action = link.map { "Warst du das nicht? Dann melde das Gerät unter „Konto → Geräte“ ab und ändere dein Passwort:\n\n\($0)" }
            ?? "Warst du das nicht? Dann melde das Gerät unter „Konto → Geräte“ ab und ändere dein Passwort."
        return NotificationMessage(subject: "WatchSwifty: Neues Gerät verbunden", body: """
            Hallo \(username),

            mit deinem WatchSwifty-Konto „\(username)“ wurde gerade eine App verbunden:

            Gerät: „\(name)“ (Name, den die App angegeben hat)
            Zeitpunkt: \(formatDateTime(date)) Uhr

            Warst du das? Dann ist alles in Ordnung.

            \(action)

            Viele Grüße
            WatchSwifty
            """)
    }

    /// The daily digest: per series (by name) the sections „Heute“, „In den nächsten Tagen“, „Neu angekündigt“; each
    /// episode once, in the section of its `headline`.
    static func digest(username: String, items: [DueNotice], today: String, baseURL: String?) -> NotificationMessage {
        let count = { (kind: NoticeKind) in items.filter { $0.headline == kind }.count }
        let parts = [
            count(.today) > 0 ? "\(count(.today)) \(count(.today) == 1 ? "Folge" : "Folgen") heute" : nil,
            count(.soon) > 0 ? "\(count(.soon)) \(count(.soon) == 1 ? "Folge" : "Folgen") in den nächsten Tagen" : nil,
            count(.announced) > 0 ? "\(count(.announced)) neu angekündigt" : nil,
        ].compactMap { $0 }
        let series = Dictionary(grouping: items, by: \.seriesTMDBID).values.sorted { a, b in
            let order = a[0].seriesName.localizedCaseInsensitiveCompare(b[0].seriesName)
            return order == .orderedSame ? a[0].seriesTMDBID < b[0].seriesTMDBID : order == .orderedAscending
        }
        let blocks = series.map { episodes -> String in
            var lines = [oneLine(episodes[0].seriesName)]
            for (kind, title) in [(NoticeKind.today, "Heute"), (.soon, "In den nächsten Tagen"), (.announced, "Neu angekündigt")] {
                let section = episodes.filter { $0.headline == kind }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                guard !section.isEmpty else { continue }
                lines.append("  \(title):")
                lines += section.map { "  " + line($0, kind: kind, today: today) }
            }
            if let baseURL { lines.append("  \(baseURL)/tv/\(episodes[0].seriesTMDBID)") }
            return lines.joined(separator: "\n")
        }
        let body = """
            Hallo \(username),

            es gibt Neues zu deinen beobachteten Serien:

            \(blocks.joined(separator: "\n\n"))

            Die Termine sind die von TMDB – bei US-Serien oft einen Tag vor der Verfügbarkeit hier.
            Abschalten unter „Konto → Benachrichtigungen“.

            Viele Grüße
            WatchSwifty
            """
        return NotificationMessage(subject: "WatchSwifty: " + parts.joined(separator: ", "), body: body)
    }

    private static func line(_ item: DueNotice, kind: NoticeKind, today: String) -> String {
        let code = String(format: "S%02dE%02d", item.season, item.number)
        let head = "\(code) „\(oneLine(item.name))“"
        switch kind {
        case .today:
            return head
        case .soon:
            let days = item.airDate.map { CalendarDay.daysBetween(today, $0) } ?? 0
            return "\(head) – \(item.airDate.map(weekdayDate) ?? "")" + (days == 1 ? " (morgen)" : " (in \(days) Tagen)")
        case .announced:
            return "\(head) – " + (item.airDate.map(weekdayDate) ?? "Termin noch offen")
        }
    }

    /// `Di., 10.11.2026`
    private static func weekdayDate(_ iso: String) -> String {
        guard let date = CalendarDay.date(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EE, dd.MM.yyyy"
        return formatter.string(from: date)
    }

    /// Control characters and line breaks become spaces.
    static func oneLine(_ text: String) -> String {
        let breaking = CharacterSet.controlCharacters.union(.newlines)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
    }
}
