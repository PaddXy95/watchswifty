import Fluent
import Foundation
import Vapor

/// Konto → Benachrichtigungen (and `/v1/me/notifications`): toggles, preferred channel, KNot key.
struct NotificationPrefsService {
    /// Validation message for a channel that is not set up for the user.
    static let channelMessage = "Dieser Versandweg ist für dein Konto nicht eingerichtet."
    /// Validation message for an invalid KNot key.
    static let keyMessage = "Der Schlüssel muss mindestens 16 Zeichen lang sein, ohne Leerzeichen."

    /// The database holding the user.
    let db: any Database
    /// Seals the KNot key.
    let cipher: TokenCipher

    /// Toggles and channel need no password. Switching „neu angekündigt“ on starts its window now, so it does not
    /// report everything that appeared since the follow. Keeping the stored channel is always allowed, even while it is
    /// not available (the other one is used meanwhile).
    /// `titleAvailable` nil keeps the stored value (older apps do not send it); switching it on re-baselines the
    /// „Später ansehen“ list, so only offers appearing afterwards are reported.
    /// - Parameters:
    ///   - user: The user to update.
    ///   - announced: Notify when a new episode becomes known (``NoticeKind/announced``).
    ///   - soon: Notify in the days before the air date (``NoticeKind/soon``).
    ///   - today: Notify on the air date (``NoticeKind/today``).
    ///   - titleAvailable: The „Später ansehen“ availability switch, or nil to keep it.
    ///   - channel: The preferred channel.
    ///   - available: The channels currently available for the user.
    ///   - now: The start of the `announced` window when it is switched on.
    /// - Throws: `APIError.validation` with ``channelMessage`` for a changed channel that is not available
    ///   (while at least one is), or database errors.
    func save(user: User, announced: Bool, soon: Bool, today: Bool, titleAvailable: Bool? = nil, channel: NotifyChannel,
              available: [NotifyChannel], now: Date = .now) async throws {
        if channel != user.preferredChannel && !available.isEmpty && !available.contains(channel) {
            throw APIError.validation(Self.channelMessage)
        }
        if announced && user.notifyAnnounced != true { user.notifyAnnouncedSince = now }
        user.notifyAnnounced = announced
        user.notifySoon = soon
        user.notifyToday = today
        user.notifyChannel = channel.rawValue
        let switchedOn = titleAvailable == true && user.notifyAvailable != true
        if let titleAvailable { user.notifyAvailable = titleAvailable }
        try await user.save(on: db)
        if switchedOn {
            let notices = AvailabilityNoticeService(db: db)
            try await notices.rebaseline(userID: user.requireID())
            try await notices.dropPending(userID: user.requireID())
        }
    }

    /// Sets (or with an empty value removes) the key. No password since the 2026-11-13 feedback round: the user accepts
    /// that a hijacked session could redirect „Neues Gerät“ (spec `2026-11-13-feedback-round-design.md` §5).
    /// - Parameters:
    ///   - user: The user to update.
    ///   - raw: The entered key (trimmed); 16–512 printable ASCII characters without spaces, or empty to remove it.
    /// - Throws: `APIError.validation` with ``keyMessage`` for an invalid key, encryption errors, or database errors.
    func setWebhookKey(user: User, key raw: String) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            user.webhookKey = nil
        } else {
            guard (16...512).contains(key.count), key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
                throw APIError.validation(Self.keyMessage)
            }
            user.webhookKey = try cipher.seal(key)
        }
        try await user.save(on: db)
    }
}

extension Request {
    /// The notification preferences service for this request.
    var notificationPrefs: NotificationPrefsService {
        NotificationPrefsService(db: db, cipher: application.tokenCipher)
    }
}
