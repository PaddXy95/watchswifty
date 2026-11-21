import Fluent
import Foundation
import Vapor

/// Sends a mail with the stored settings; gives up after `deadline` (the request waits for it).
struct MailService {
    /// Source of the stored SMTP settings.
    let settings: MailSettingsService
    /// The SMTP sender (live or fake).
    let sender: any MailSender
    /// Maximum time to wait for a send before failing with `MailError.timeout`.
    let deadline: Duration

    /// Sends a mail with the stored settings.
    ///
    /// Renders the mail with the configured sender and a new `Message-ID`, then sends it.
    /// - Parameters:
    ///   - mail: The mail to send.
    ///   - now: The `Date` header value.
    /// - Throws: `MailError` (`.notConfigured`, `.timeout`, or the server's problem); database errors.
    func send(_ mail: OutgoingMail, now: Date = .now) async throws {
        guard let settings = try await settings.state().settings else { throw MailError.notConfigured }
        let domain = settings.fromAddress.split(separator: "@").last.map(String.init) ?? "watchswifty"
        let message = MailMessage.render(mail, fromAddress: settings.fromAddress, fromName: settings.fromName, date: now,
                                         messageID: "<\(UUID().uuidString.lowercased())@\(domain)>")
        let sender = sender
        let deadline = deadline
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await sender.send(message, from: settings.fromAddress, to: mail.to, settings: settings) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw MailError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Sends the test mail to an address.
    /// - Parameter raw: The recipient as entered.
    /// - Throws: `APIError.validation` for an invalid address; `MailError` when sending fails.
    func sendTest(to raw: String) async throws {
        guard let address = EmailAddress.normalize(raw) else { throw APIError.validation(EmailAddress.invalidMessage) }
        try await send(MailTexts.test(to: address))
    }
}

extension Application {
    /// A mail service for background code.
    var mail: MailService {
        MailService(settings: MailSettingsService(db: db, cipher: tokenCipher), sender: mailSender, deadline: appConfig.mailDeadline)
    }
}

extension Request {
    /// A mail service for this request.
    var mail: MailService {
        MailService(settings: mailSettings, sender: application.mailSender, deadline: application.appConfig.mailDeadline)
    }
}
