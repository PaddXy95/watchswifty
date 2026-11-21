import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/me/notifications`: the user's notification preferences and channels.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the preferences.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getNotificationPrefs(_ input: Operations.getNotificationPrefs.Input) async throws -> Operations.getNotificationPrefs.Output {
        let user = try APIContext.requireUser()
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: try APIContext.request()))))
    }

    /// Handles `PUT /api/v1/me/notifications`: saves which notices the user gets and over which channel via
    /// `NotificationPrefsService.save` (an unknown channel falls back to mail).
    /// - Parameter input: The generated operation input (JSON body with the switches and the channel).
    /// - Returns: `.ok` with the updated preferences.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `NotificationPrefsService.save`.
    func setNotificationPrefs(_ input: Operations.setNotificationPrefs.Input) async throws -> Operations.setNotificationPrefs.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let channel = NotifyChannel(rawValue: body.channel.rawValue) ?? .mail
        try await request.notificationPrefs.save(user: user, announced: body.announced, soon: body.soon, today: body.today, titleAvailable: body.titleAvailable, channel: channel,
                                                 available: try await request.notifications.availableChannels(for: user))
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    /// Handles `PUT /api/v1/me/notifications/webhook-key`: stores the user's KNot webhook key via
    /// `NotificationPrefsService.setWebhookKey`.
    /// - Parameter input: The generated operation input (JSON body with the key).
    /// - Returns: `.ok` with the updated preferences.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `NotificationPrefsService.setWebhookKey`.
    func setWebhookKey(_ input: Operations.setWebhookKey.Input) async throws -> Operations.setWebhookKey.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        // `currentPassword` is ignored (no longer needed, older apps still send it).
        try await request.notificationPrefs.setWebhookKey(user: user, key: body.key)
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    /// Handles `DELETE /api/v1/me/notifications/webhook-key`: removes the user's KNot webhook key (stores an empty
    /// key).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the updated preferences.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, errors of
    ///   `NotificationPrefsService.setWebhookKey`.
    func deleteWebhookKey(_ input: Operations.deleteWebhookKey.Input) async throws -> Operations.deleteWebhookKey.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await request.notificationPrefs.setWebhookKey(user: user, key: "")
        return .ok(.init(body: .json(try await Self.notificationPrefs(user, request: request))))
    }

    /// Handles `POST /api/v1/me/notifications/test`: sends a test notice over the user's channel
    /// (`NotificationService`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `NotifyError` when no
    ///   channel is usable or sending fails (mail and webhook failures are wrapped; mapped by `APIError.from`).
    func sendTestNotification(_ input: Operations.sendTestNotification.Input) async throws -> Operations.sendTestNotification.Output {
        let user = try APIContext.requireUser()
        try await APIContext.request().notifications.send(NotificationTexts.test(username: user.username), to: user)
        return .noContent(.init())
    }

    /// Handles `GET /api/v1/admin/notifications`: the server-wide notification settings
    /// (`NotificationSettingsService`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the admin settings.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, database errors.
    func getNotificationSettings(_ input: Operations.getNotificationSettings.Input) async throws -> Operations.getNotificationSettings.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(Self.adminNotifications(try await APIContext.request().notificationSettings.settings()))))
    }

    /// Handles `PUT /api/v1/admin/notifications`: saves the daily run time and the webhook URL via
    /// `NotificationSettingsService.save`.
    /// - Parameter input: The generated operation input (JSON body).
    /// - Returns: `.ok` with the saved admin settings.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `NotificationSettingsService.save`.
    func setNotificationSettings(_ input: Operations.setNotificationSettings.Input) async throws -> Operations.setNotificationSettings.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let saved = try await APIContext.request().notificationSettings.save(dailyRunTime: body.dailyRunTime, webhookURL: body.webhookUrl)
        return .ok(.init(body: .json(Self.adminNotifications(saved))))
    }

    /// Builds the user's `NotificationPrefs` schema.
    ///
    /// The active channel is the preferred one when available, otherwise the first available channel.
    /// - Parameters:
    ///   - user: The signed-in user.
    ///   - request: The current request.
    /// - Returns: The schema value.
    /// - Throws: Database errors.
    static func notificationPrefs(_ user: User, request: Request) async throws -> Components.Schemas.NotificationPrefs {
        let available = try await request.notifications.availableChannels(for: user)
        let active = available.contains(user.preferredChannel) ? user.preferredChannel : available.first
        let settings = try await request.notificationSettings.settings()
        let keyState = user.webhookKeyState(request.application.tokenCipher)
        return .init(titleAvailable: user.notifyAvailable == true,
                     announced: user.notifyAnnounced == true, soon: user.notifySoon == true, today: user.notifyToday == true,
                     channel: schema(user.preferredChannel), activeChannel: active.map(schema),
                     availableChannels: available.map(schema), webhookConfigured: settings.webhookURL != nil,
                     hasWebhookKey: keyState != .none, dailyRunTime: settings.dailyRunTime)
    }

    /// Builds the admin's notification settings schema, with the server time zone and the next run time.
    /// - Parameter settings: The stored settings.
    /// - Returns: The schema value.
    static func adminNotifications(_ settings: NotificationSettings) -> Components.Schemas.AdminNotificationSettings {
        .init(dailyRunTime: settings.dailyRunTime, timeZone: TimeZone.current.identifier, webhookUrl: settings.webhookURL,
              lastRunAt: settings.lastRunAt,
              nextRunAt: DailySchedule.nextRun(after: .now, time: settings.dailyRunTime, timeZone: .current))
    }

    /// Maps a notification channel to its schema value.
    /// - Parameter channel: The channel.
    /// - Returns: The schema value.
    private static func schema(_ channel: NotifyChannel) -> Components.Schemas.NotifyChannel {
        switch channel {
        case .mail: .mail
        case .webhook: .webhook
        }
    }
}
