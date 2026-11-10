import Foundation

/// The mails WatchSwifty sends (plain text, German).
enum MailTexts {
    static func test(to: String) -> OutgoingMail {
        OutgoingMail(to: to, subject: "WatchSwifty: Testmail", body: """
            Hallo,

            diese Testmail zeigt, dass WatchSwifty Mails verschicken kann.

            Viele Grüße
            WatchSwifty
            """)
    }

    static func reset(to: String, username: String, link: String) -> OutgoingMail {
        OutgoingMail(to: to, subject: "WatchSwifty: Passwort zurücksetzen", body: """
            Hallo \(username),

            für dein WatchSwifty-Konto „\(username)“ wurde ein neues Passwort angefordert. Über diesen Link setzt du es \
            (er gilt eine Stunde und nur einmal):

            \(link)

            Warst du das nicht? Dann ignoriere diese Mail – dein Passwort bleibt, wie es ist.

            Viele Grüße
            WatchSwifty
            """)
    }

    static func newDevice(to: String, username: String, device: String, at date: Date, link: String) -> OutgoingMail {
        // The app chooses the device name: kept on one line, so it cannot add text of its own to the mail.
        let breaking = CharacterSet.controlCharacters.union(.newlines)
        let name = String(String.UnicodeScalarView(device.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
        return OutgoingMail(to: to, subject: "WatchSwifty: Neues Gerät verbunden", body: """
            Hallo \(username),

            mit deinem WatchSwifty-Konto „\(username)“ wurde gerade eine App verbunden:

            Gerät: „\(name)“ (Name, den die App angegeben hat)
            Zeitpunkt: \(formatDateTime(date)) Uhr

            Warst du das? Dann ist alles in Ordnung.

            Warst du das nicht? Dann melde das Gerät unter „Konto → Geräte“ ab und ändere dein Passwort:

            \(link)

            Viele Grüße
            WatchSwifty
            """)
    }

    /// Admin's „Verknüpfungslink“: binds whoever signs in at the provider to this account.
    static func ssoLink(to: String, username: String, inviter: String, ssoName: String, link: String, expires: Date) -> OutgoingMail {
        OutgoingMail(to: to, subject: "WatchSwifty: Konto mit \(ssoName) verknüpfen", body: """
            Hallo \(username),

            \(inviter) hat dir einen Link geschickt, mit dem du dein WatchSwifty-Konto „\(username)“ mit \(ssoName) verknüpfst \
            (gültig bis \(CalendarDay.display(CalendarDay.today(now: expires))), nur einmal nutzbar):

            \(link)

            Danach meldest du dich immer über \(ssoName) an.

            Hast du das nicht erwartet? Dann ignoriere diese Mail.

            Viele Grüße
            WatchSwifty
            """)
    }

    /// With `ssoName` the invitation can also be accepted through the OIDC provider; without password login only so.
    static func invite(to: String, username: String, inviter: String, link: String, expires: Date, ssoName: String? = nil,
                       passwordLogin: Bool = true) -> OutgoingMail {
        let until = CalendarDay.display(CalendarDay.today(now: expires))
        let how = switch (ssoName, passwordLogin) {
        case (nil, _): "Über diesen Link legst du dein Passwort fest (gültig bis \(until)):"
        case (let name?, true): "Über diesen Link legst du dein Passwort fest oder verknüpfst dein Konto mit \(name) (gültig bis \(until)):"
        case (let name?, false): "Über diesen Link meldest du dich über \(name) an und nimmst die Einladung an (gültig bis \(until)):"
        }
        return OutgoingMail(to: to, subject: "Einladung zu WatchSwifty", body: """
            Hallo,

            \(inviter) hat dich zu WatchSwifty eingeladen, einem Tracker für Serien und Filme.
            Dein Benutzername: \(username)

            \(how)

            \(link)

            Danach trägst du unter „Konto“ deinen eigenen kostenlosen TMDB-Token ein – die Seite erklärt, wie du ihn bekommst.

            Viele Grüße
            WatchSwifty
            """)
    }
}
