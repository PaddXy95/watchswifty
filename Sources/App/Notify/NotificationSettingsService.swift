import Fluent
import Foundation
import Vapor

/// System → Benachrichtigungen: time of the daily pass and the KNot webhook address (not secret, stored unsealed).
struct NotificationSettings: Equatable, Sendable {
    /// Time of the daily pass as `HH:MM` (server time zone).
    var dailyRunTime: String
    /// The KNot webhook address, or nil when none is set.
    var webhookURL: String?
    /// Start of the last daily pass.
    var lastRunAt: Date?
}

/// Reads and saves System → Benachrichtigungen (notifications) in `app_settings`, and records the last daily pass.
struct NotificationSettingsService {
    /// Validation message for an invalid time.
    static let timeMessage = "Uhrzeit bitte als HH:MM angeben, z. B. 07:00."
    /// Validation message for an invalid webhook address.
    static let webhookURLMessage = "Webhook-Adresse: z. B. https://knot.example.lan/hook – ohne Benutzer, ?… und #…."

    /// The database holding `app_settings`.
    let db: any Database
    /// Woken after a save so the waiting daily loop picks up a new time at once.
    var trigger: DailyRunTrigger? = nil

    /// The current settings; an unset or unparsable time reads as ``DailySchedule/defaultTime``.
    /// - Returns: The settings.
    /// - Throws: Database errors.
    func settings() async throws -> NotificationSettings {
        let row = try await AppSettings.query(on: db).first()
        return NotificationSettings(dailyRunTime: row?.dailyRunTime.flatMap(DailySchedule.normalized) ?? DailySchedule.defaultTime,
                                    webhookURL: row?.webhookURL, lastRunAt: row?.dailyRunAt)
    }

    /// An empty or missing address removes the webhook.
    ///
    /// Also wakes the daily loop, so a new time applies at once.
    /// - Parameters:
    ///   - dailyRunTime: The new time (`H:MM` or `HH:MM`).
    ///   - rawURL: The new webhook address (see ``webhookURL(_:)``).
    /// - Returns: The saved settings.
    /// - Throws: `APIError.validation` with ``timeMessage`` or ``webhookURLMessage``, or database errors.
    @discardableResult
    func save(dailyRunTime: String, webhookURL rawURL: String?) async throws -> NotificationSettings {
        guard let time = DailySchedule.normalized(dailyRunTime) else { throw APIError.validation(Self.timeMessage) }
        var url: String?
        if let rawURL, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let valid = Self.webhookURL(rawURL) else { throw APIError.validation(Self.webhookURLMessage) }
            url = valid
        }
        let row = try await AppSettings.query(on: db).first() ?? AppSettings()
        row.dailyRunTime = time
        row.webhookURL = url
        try await row.save(on: db)
        trigger?.wake()
        return try await settings()
    }

    /// Removes the webhook address.
    /// - Throws: Database errors.
    func removeWebhook() async throws {
        guard let row = try await AppSettings.query(on: db).first() else { return }
        row.webhookURL = nil
        try await row.save(on: db)
    }

    /// Records the start of the last complete daily pass.
    /// - Parameter date: The pass's start time.
    /// - Throws: Database errors.
    func markRun(at date: Date) async throws {
        let row = try await AppSettings.query(on: db).first() ?? AppSettings()
        row.dailyRunAt = date
        try await row.save(on: db)
    }

    /// `http(s)://host[:port][/path]`, trimmed; nil with user info, query or fragment (the key belongs in the header,
    /// never in an address that may end up in logs).
    /// - Parameter raw: The entered address.
    /// - Returns: The trimmed address, or nil when invalid.
    static func webhookURL(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("?"), !text.contains("#"), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return text
    }
}

extension Application {
    /// The notification settings service, wired to the daily run trigger.
    var notificationSettings: NotificationSettingsService { NotificationSettingsService(db: db, trigger: dailyRunTrigger) }
}

extension Request {
    /// The notification settings service for this request, wired to the daily run trigger.
    var notificationSettings: NotificationSettingsService {
        NotificationSettingsService(db: db, trigger: application.dailyRunTrigger)
    }
}
