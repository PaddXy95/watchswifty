import Foundation

/// Notifications a user gets by mail or webhook (plain text, German).
enum NotificationTexts {
    /// The test message sent from the account page or `POST /v1/me/notifications/test`.
    /// - Parameter username: The recipient's username.
    /// - Returns: The message.
    static func test(username: String) -> NotificationMessage {
        NotificationMessage(subject: "WatchSwifty: Testnachricht", body: """
            Hallo \(username),

            diese Testnachricht zeigt, dass deine Benachrichtigungen ankommen.

            Viele Grüße
            WatchSwifty
            """)
    }

    /// The „Neues Gerät verbunden“ (new device connected) warning after an app was connected to the account.
    /// - Parameters:
    ///   - username: The account's username.
    ///   - device: The device name the app sent (flattened to one line).
    ///   - date: When the app was connected.
    ///   - link: A link to the account's device list, if a base address is known.
    /// - Returns: The message.
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
    ///
    /// After the episodes follows „Jetzt bei deinen Diensten“ (now at your services) for „Später ansehen“ titles; the
    /// subject counts each section.
    /// - Parameters:
    ///   - username: The recipient's username.
    ///   - items: The due episode notices.
    ///   - available: Titles that became available at the user's services.
    ///   - today: Today as `YYYY-MM-DD` (for „morgen“/„in N Tagen“).
    ///   - baseURL: WatchSwifty's address for links, if known.
    /// - Returns: The message.
    static func digest(username: String, items: [DueNotice], available: [AvailabilityDue] = [], today: String,
                       baseURL: String?) -> NotificationMessage {
        let count = { (kind: NoticeKind) in items.filter { $0.headline == kind }.count }
        let parts = [
            count(.today) > 0 ? "\(count(.today)) \(count(.today) == 1 ? "Folge" : "Folgen") heute" : nil,
            count(.soon) > 0 ? "\(count(.soon)) \(count(.soon) == 1 ? "Folge" : "Folgen") in den nächsten Tagen" : nil,
            count(.announced) > 0 ? "\(count(.announced)) neu angekündigt" : nil,
            available.isEmpty ? nil : "\(available.count) Titel jetzt verfügbar",
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
        var sections: [String] = []
        if !blocks.isEmpty { sections.append(blocks.joined(separator: "\n\n")) }
        if !available.isEmpty {
            var lines = ["Jetzt bei deinen Diensten:"]
            for title in available {
                let what = [title.year.map(String.init), title.kind == .movie ? "Film" : "Serie"].compactMap { $0 }.joined(separator: ", ")
                lines.append("  „\(oneLine(title.name))“ (\(what)) – " + title.providers.map(oneLine).joined(separator: ", "))
                if let baseURL { lines.append("  \(baseURL)/\(title.kind.rawValue)/\(title.tmdbID)") }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let intro = items.isEmpty ? "es gibt Neues zu deiner Liste „Später ansehen“:" : "es gibt Neues zu deinen beobachteten Serien:"
        let notes = [
            items.isEmpty ? nil : "Die Termine sind die von TMDB – bei US-Serien oft einen Tag vor der Verfügbarkeit hier.",
            available.isEmpty ? nil : "Verfügbarkeit: JustWatch",
            "Abschalten unter „Konto → Benachrichtigungen“.",
        ].compactMap { $0 }
        let body = """
            Hallo \(username),

            \(intro)

            \(sections.joined(separator: "\n\n"))

            \(notes.joined(separator: "\n"))

            Viele Grüße
            WatchSwifty
            """
        return NotificationMessage(subject: "WatchSwifty: " + parts.joined(separator: ", "), body: body)
    }

    /// One episode line of a digest section: code and name, plus the date for `soon` and `announced`.
    /// - Parameters:
    ///   - item: The episode.
    ///   - kind: The section it is listed in.
    ///   - today: Today as `YYYY-MM-DD`.
    /// - Returns: The line.
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
    /// - Parameter iso: A `YYYY-MM-DD` date.
    /// - Returns: The German date with weekday, or `iso` unchanged when it is invalid.
    private static func weekdayDate(_ iso: String) -> String {
        guard let date = CalendarDay.date(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EE, dd.MM.yyyy"
        return formatter.string(from: date)
    }

    /// Control characters and line breaks become spaces.
    /// - Parameter text: Untrusted text (series names, device names).
    /// - Returns: The text on a single line.
    static func oneLine(_ text: String) -> String {
        let breaking = CharacterSet.controlCharacters.union(.newlines)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
    }
}
