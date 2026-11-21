import Foundation

/// The mails WatchSwifty sends (plain text, German).
enum MailTexts {
    /// Test mail sent from the system page.
    /// - Parameter to: Recipient address.
    /// - Returns: The mail.
    static func test(to: String) -> OutgoingMail {
        OutgoingMail(to: to, subject: "WatchSwifty: Testmail", body: """
            Hallo,

            diese Testmail zeigt, dass WatchSwifty Mails verschicken kann.

            Viele Grüße
            WatchSwifty
            """)
    }

    /// „Passwort zurücksetzen“ (reset password) mail with a one-time link valid for one hour.
    /// - Parameters:
    ///   - to: Recipient address.
    ///   - username: The account's username.
    ///   - link: The reset link.
    /// - Returns: The mail.
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

    /// Admin's „Verknüpfungslink“: binds whoever signs in at the provider to this account.
    /// - Parameters:
    ///   - to: Recipient address.
    ///   - username: The account's username.
    ///   - inviter: Username of the admin who created the link.
    ///   - ssoName: Display name of the OIDC provider.
    ///   - link: The one-time linking link.
    ///   - expires: When the link expires (shown as a date).
    /// - Returns: The mail.
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

    /// Invitation mail for an account without password.
    ///
    /// With `ssoName` the invitation can also be accepted through the OIDC provider; without password login only so.
    /// - Parameters:
    ///   - to: Recipient address.
    ///   - username: The new account's username.
    ///   - inviter: Username of the inviting admin.
    ///   - link: The invitation link.
    ///   - expires: When the link expires (shown as a date).
    ///   - ssoName: Display name of the OIDC provider, if set up.
    ///   - passwordLogin: Whether password login is enabled.
    /// - Returns: The mail.
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
