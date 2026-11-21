import Fluent
import Foundation
import Vapor

/// How a user gets notifications.
enum NotifyChannel: String, Codable, CaseIterable, Sendable {
    /// `mail`: to the user's own e-mail address; `webhook`: to the admin's KNot webhook with the user's key.
    case mail, webhook
}

/// State of a user's stored KNot webhook key.
enum WebhookKeyState: Equatable, Sendable {
    /// No key stored.
    case none
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    /// The decrypted key.
    case key(String)
}

extension User {
    /// The channel the user chose; `mail` when none or an unknown value is stored.
    var preferredChannel: NotifyChannel { notifyChannel.flatMap(NotifyChannel.init(rawValue:)) ?? .mail }

    /// Decrypts the user's KNot key.
    /// - Parameter cipher: The server's token cipher.
    /// - Returns: Whether a key is stored and readable, with the key.
    func webhookKeyState(_ cipher: TokenCipher) -> WebhookKeyState {
        guard let stored = webhookKey, !stored.isEmpty else { return .none }
        return cipher.open(stored).map(WebhookKeyState.key) ?? .unreadable
    }
}

/// A notification that could not be sent, with a German message (mail or webhook reason).
struct NotifyError: Error, Equatable, Sendable {
    /// The German reason shown to the user.
    let message: String

    /// No channel is set up for the user.
    static let notConfigured = NotifyError(message: "Für dein Konto ist kein Versandweg eingerichtet.")
}

/// Sends a user's notifications (digest, test, „Neues Gerät“) by mail or KNot webhook. Reset, invitation and SSO links
/// never go through here.
struct NotificationService {
    /// The database.
    let db: any Database
    /// Decrypts e-mail addresses and KNot keys.
    let cipher: TokenCipher
    /// The mail path.
    let mail: MailService
    /// The KNot webhook path.
    let webhook: any WebhookSender
    /// System notification settings (webhook address).
    let settings: NotificationSettingsService
    /// The login setup (for the SSO provider's address in ``baseURL()``).
    let login: LoginSettings

    /// Mail: mail set up and an own readable address. Webhook: address under System and an own readable key.
    /// - Parameter user: The user.
    /// - Returns: The available channels, mail first.
    /// - Throws: Database errors.
    func availableChannels(for user: User) async throws -> [NotifyChannel] {
        var channels: [NotifyChannel] = []
        if try await mail.settings.state().settings != nil, user.emailState(cipher).address != nil { channels.append(.mail) }
        if try await settings.settings().webhookURL != nil, case .key = user.webhookKeyState(cipher) { channels.append(.webhook) }
        return channels
    }

    /// The preferred channel when available, else the other one, else none.
    /// - Parameter user: The user.
    /// - Returns: The channel a notification would use, or nil when none is set up.
    /// - Throws: Database errors.
    func activeChannel(for user: User) async throws -> NotifyChannel? {
        let available = try await availableChannels(for: user)
        return available.contains(user.preferredChannel) ? user.preferredChannel : available.first
    }

    /// Throws `NotifyError`; returns the channel used.
    /// - Parameters:
    ///   - message: The notification.
    ///   - user: The recipient.
    /// - Returns: The channel used.
    /// - Throws: ``NotifyError/notConfigured`` without a usable channel, a ``NotifyError`` with the mail or webhook
    ///   failure's message, or database errors.
    @discardableResult
    func send(_ message: NotificationMessage, to user: User) async throws -> NotifyChannel {
        guard let channel = try await activeChannel(for: user) else { throw NotifyError.notConfigured }
        do {
            switch channel {
            case .mail:
                guard let address = user.emailState(cipher).address else { throw NotifyError.notConfigured }
                try await mail.send(OutgoingMail(to: address, subject: message.subject, body: message.body))
            case .webhook:
                guard let url = try await settings.settings().webhookURL, case .key(let key) = user.webhookKeyState(cipher) else {
                    throw NotifyError.notConfigured
                }
                try await webhook.send(message, url: url, key: key)
            }
        } catch let error as MailError {
            throw NotifyError(message: error.message)
        } catch let error as WebhookError {
            throw NotifyError(message: error.message)
        }
        return channel
    }

    /// „Adresse von WatchSwifty“ for links: from the mail settings, else the SSO provider's canonical address.
    /// - Returns: The address, or nil when neither is set up.
    /// - Throws: Database errors.
    func baseURL() async throws -> String? {
        if let base = try await mail.settings.state().settings?.baseURL { return base }
        return login.oidc?.canonicalOrigin
    }
}

extension Application {
    /// The notification service built from the application's collaborators.
    var notifications: NotificationService {
        NotificationService(db: db, cipher: tokenCipher, mail: mail, webhook: webhookSender, settings: notificationSettings,
                            login: loginSettings.current)
    }
}

extension Request {
    /// The notification service for this request.
    var notifications: NotificationService {
        NotificationService(db: db, cipher: application.tokenCipher, mail: mail, webhook: application.webhookSender,
                            settings: notificationSettings, login: application.loginSettings.current)
    }
}
