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

    static func invite(to: String, username: String, inviter: String, link: String, expires: Date) -> OutgoingMail {
        OutgoingMail(to: to, subject: "Einladung zu WatchSwifty", body: """
            Hallo,

            \(inviter) hat dich zu WatchSwifty eingeladen, einem Tracker für Serien und Filme.
            Dein Benutzername: \(username)

            Über diesen Link legst du dein Passwort fest (gültig bis \(CalendarDay.display(CalendarDay.today(now: expires)))):

            \(link)

            Danach trägst du unter „Konto“ deinen eigenen kostenlosen TMDB-Token ein – die Seite erklärt, wie du ihn bekommst.

            Viele Grüße
            WatchSwifty
            """)
    }
}
