import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getNotificationPrefs(_ input: Operations.getNotificationPrefs.Input) async throws -> Operations.getNotificationPrefs.Output {
        let user = try APIContext.requireUser()
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: try APIContext.request()))))
    }

    func setNotificationPrefs(_ input: Operations.setNotificationPrefs.Input) async throws -> Operations.setNotificationPrefs.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let channel = NotifyChannel(rawValue: body.channel.rawValue) ?? .mail
        try await request.notificationPrefs.save(user: user, announced: body.announced, soon: body.soon, today: body.today, channel: channel,
                                                 available: try await request.notifications.availableChannels(for: user))
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    func setWebhookKey(_ input: Operations.setWebhookKey.Input) async throws -> Operations.setWebhookKey.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        // `currentPassword` is ignored (no longer needed, older apps still send it).
        try await request.notificationPrefs.setWebhookKey(user: user, key: body.key)
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    func deleteWebhookKey(_ input: Operations.deleteWebhookKey.Input) async throws -> Operations.deleteWebhookKey.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await request.notificationPrefs.setWebhookKey(user: user, key: "")
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    func sendTestNotification(_ input: Operations.sendTestNotification.Input) async throws -> Operations.sendTestNotification.Output {
        let user = try APIContext.requireUser()
        try await APIContext.request().notifications.send(NotificationTexts.test(username: user.username), to: user)
        return .noContent(.init())
    }

    func getNotificationSettings(_ input: Operations.getNotificationSettings.Input) async throws -> Operations.getNotificationSettings.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(Self.adminNotifications(try await APIContext.request().notificationSettings.settings()))))
    }

    func setNotificationSettings(_ input: Operations.setNotificationSettings.Input) async throws -> Operations.setNotificationSettings.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let saved = try await APIContext.request().notificationSettings.save(dailyRunTime: body.dailyRunTime, webhookURL: body.webhookUrl)
        return .ok(.init(body: .json(Self.adminNotifications(saved))))
    }

    static func notificationPrefs(_ user: User, request: Request) async throws -> Components.Schemas.NotificationPrefs {
        let available = try await request.notifications.availableChannels(for: user)
        let active = available.contains(user.preferredChannel) ? user.preferredChannel : available.first
        let settings = try await request.notificationSettings.settings()
        let keyState = user.webhookKeyState(request.application.tokenCipher)
        return .init(announced: user.notifyAnnounced == true, soon: user.notifySoon == true, today: user.notifyToday == true,
                     channel: schema(user.preferredChannel), activeChannel: active.map(schema),
                     availableChannels: available.map(schema), webhookConfigured: settings.webhookURL != nil,
                     hasWebhookKey: keyState != .none, dailyRunTime: settings.dailyRunTime)
    }

    static func adminNotifications(_ settings: NotificationSettings) -> Components.Schemas.AdminNotificationSettings {
        .init(dailyRunTime: settings.dailyRunTime, timeZone: TimeZone.current.identifier, webhookUrl: settings.webhookURL,
              lastRunAt: settings.lastRunAt,
              nextRunAt: DailySchedule.nextRun(after: .now, time: settings.dailyRunTime, timeZone: .current))
    }

    private static func schema(_ channel: NotifyChannel) -> Components.Schemas.NotifyChannel {
        switch channel {
        case .mail: .mail
        case .webhook: .webhook
        }
    }
}
