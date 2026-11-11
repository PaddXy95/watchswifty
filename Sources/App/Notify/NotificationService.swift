import Fluent
import Foundation
import Vapor

/// How a user gets notifications.
enum NotifyChannel: String, Codable, CaseIterable, Sendable {
    case mail, webhook
}

enum WebhookKeyState: Equatable, Sendable {
    case none
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    case key(String)
}

extension User {
    var preferredChannel: NotifyChannel { notifyChannel.flatMap(NotifyChannel.init(rawValue:)) ?? .mail }

    func webhookKeyState(_ cipher: TokenCipher) -> WebhookKeyState {
        guard let stored = webhookKey, !stored.isEmpty else { return .none }
        return cipher.open(stored).map(WebhookKeyState.key) ?? .unreadable
    }
}

/// A notification that could not be sent, with a German message (mail or webhook reason).
struct NotifyError: Error, Equatable, Sendable {
    let message: String

    static let notConfigured = NotifyError(message: "Für dein Konto ist kein Versandweg eingerichtet.")
}

/// Sends a user's notifications (digest, test, „Neues Gerät“) by mail or KNot webhook. Reset, invitation and SSO links
/// never go through here.
struct NotificationService {
    let db: any Database
    let cipher: TokenCipher
    let mail: MailService
    let webhook: any WebhookSender
    let settings: NotificationSettingsService
    let login: LoginSettings

    /// Mail: mail set up and an own readable address. Webhook: address under System and an own readable key.
    func availableChannels(for user: User) async throws -> [NotifyChannel] {
        var channels: [NotifyChannel] = []
        if try await mail.settings.state().settings != nil, user.emailState(cipher).address != nil { channels.append(.mail) }
        if try await settings.settings().webhookURL != nil, case .key = user.webhookKeyState(cipher) { channels.append(.webhook) }
        return channels
    }

    /// The preferred channel when available, else the other one, else none.
    func activeChannel(for user: User) async throws -> NotifyChannel? {
        let available = try await availableChannels(for: user)
        return available.contains(user.preferredChannel) ? user.preferredChannel : available.first
    }

    /// Throws `NotifyError`; returns the channel used.
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
    func baseURL() async throws -> String? {
        if let base = try await mail.settings.state().settings?.baseURL { return base }
        return login.oidc?.canonicalOrigin
    }
}

extension Application {
    var notifications: NotificationService {
        NotificationService(db: db, cipher: tokenCipher, mail: mail, webhook: webhookSender, settings: notificationSettings,
                            login: loginSettings.current)
    }
}

extension Request {
    var notifications: NotificationService {
        NotificationService(db: db, cipher: application.tokenCipher, mail: mail, webhook: application.webhookSender,
                            settings: notificationSettings, login: application.loginSettings.current)
    }
}
