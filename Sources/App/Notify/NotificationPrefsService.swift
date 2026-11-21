import Fluent
import Foundation
import Vapor

/// Konto → Benachrichtigungen (and `/v1/me/notifications`): toggles, preferred channel, KNot key.
struct NotificationPrefsService {
    static let channelMessage = "Dieser Versandweg ist für dein Konto nicht eingerichtet."
    static let keyMessage = "Der Schlüssel muss mindestens 16 Zeichen lang sein, ohne Leerzeichen."

    let db: any Database
    let cipher: TokenCipher

    /// Toggles and channel need no password. Switching „neu angekündigt“ on starts its window now, so it does not
    /// report everything that appeared since the follow. Keeping the stored channel is always allowed, even while it is
    /// not available (the other one is used meanwhile).
    /// `titleAvailable` nil keeps the stored value (older apps do not send it); switching it on re-baselines the
    /// „Später ansehen“ list, so only offers appearing afterwards are reported.
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
    var notificationPrefs: NotificationPrefsService {
        NotificationPrefsService(db: db, cipher: application.tokenCipher)
    }
}
