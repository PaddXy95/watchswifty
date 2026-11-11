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

    /// Control characters and line breaks become spaces.
    static func oneLine(_ text: String) -> String {
        let breaking = CharacterSet.controlCharacters.union(.newlines)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
    }
}
