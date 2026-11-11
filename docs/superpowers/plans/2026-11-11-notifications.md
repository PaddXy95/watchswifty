# Notifications (new episodes, mail or KNot webhook) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users who follow a series get one daily digest (mail or KNot webhook) about newly announced episodes, episodes airing in 1–3 days and episodes airing today; the daily pass runs at an admin-chosen time.

**Architecture:** A new feature folder `Sources/App/Notify/` holds the schedule, the admin settings (time + webhook address in `app_settings`), the per-user preferences (columns on `users`), the delivery service (`NotificationService`: mail via the existing `MailService` or webhook via a new `WebhookSender`), the due-notice computation over a new `episode_notices` table and the digest texts. `DailyRefreshLifecycle` becomes a scheduler that runs the existing pass plus the notification pass at the configured time. Web (System, Konto) and App API call the same services.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, AsyncHTTPClient (new direct dependency, already resolved at 1.37.0), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-notifications-design.md` (sections referenced as §1–§8).

## Global Constraints

- Everything a user sees (UI, error messages, notification texts, README, CHANGELOG) is German; identifiers, comments, plan and commit messages English (Conventional Commits).
- Upcoming features `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`: `any Protocol`, import every module whose members a file uses (`import Fluent` for queries, `import AsyncHTTPClient` for the client).
- Migrations are appended at the **end** of the list in `configure.swift`, in task order.
- "Today" is always `AppConfig.today` (tests: `2026-11-07`), never `Date()`, for day logic; wall-clock `now: Date` is a parameter with default `.now` wherever a test needs to pin it.
- Only regular episodes (`season >= 1`) of series the user **follows** (`user_titles.followed == true`, hidden or not).
- Secrets: the webhook key is sealed with `TokenCipher`, never rendered after saving, never logged, never in an API response. Webhook address and daily time are stored unsealed in `app_settings`.
- Reset, invitation, SSO link and the System test mail stay mail-only; only the digest, the test notification and „Neues Gerät verbunden“ go through `NotificationService`.
- Webhook request: `POST <webhookURL>`, headers `X-API-Key: <key>`, `Content-Type: application/json`; body exactly `{"subject": …, "body": …}`; 60 s total deadline; redirects are not followed (3xx = error).
- Daily time default `07:00`, format `HH:MM`, server time zone (`TimeZone.current`).
- Thresholds (spec §4): „erkannt“ only if air date empty or at most **7** days before today; „in 3 Tagen“ when the air date is **1–3** days after today; „heute“ when air date == today; cleanup when the episode's current air date is more than **30** days before today; boot run only if the last run is more than **24 h** ago, after **60 s**.
- Per-user isolation: a user's preferences, key and notices are only ever read through the logged-in user; other users' IDs give 404 (API) as elsewhere.
- KNot repository link shown on System: `https://github.com/nexus421/KNot`.
- `swift test` green at every commit. No push.

## Review Focus

1. A user follows a series whose 8 future episodes are already cached → no „erkannt“ for any of them; only „in 3 Tagen“/„heute“ later. Test: `noAnnouncedForEpisodesKnownBeforeFollow` (Task 6).
2. TMDB moves unaired episodes (S02E06→S03E01, same TMDB episode id) and drops a placeholder → no second „erkannt“, no reminder for the dropped/old row. Tests: `renumberedEpisodeNotAnnouncedTwice`, `staleRowGetsNoReminder` (Task 6).
3. KNot down or answering 502/429 → nothing recorded, the same items go out the next day; one user's failure does not stop the next user. Test: `failedSendIsRetriedNextDay`, `oneFailureDoesNotStopOthers` (Task 8).
4. Admin enters a webhook URL with `?apiKey=…`, a user-info part, or a non-http scheme → rejected with the German message; a webhook answering 302 → error, the key never reaches the redirect target. Tests: `rejectsQueryUserInfoAndScheme` (Task 3), `liveSenderDoesNotFollowRedirect` (Task 4).
5. Admin changes the daily time to 05:30 while the loop sleeps toward 07:00 → the loop wakes and sleeps toward 05:30; a time that does not exist on a DST day runs once at the next possible moment. Tests: `sleepReturnsEarlyOnWake`, `nextRunSkipsMissingDSTHour` (Task 3).

## Files

New folder `Sources/App/Notify/`:
- `NotifyMigrations.swift` – all new migrations except the episode/follow columns.
- `DailySchedule.swift` – `DailySchedule` (pure time math), `DailyRunTrigger` (sleep/wake).
- `NotificationSettingsService.swift` – admin settings (time, webhook URL, last run).
- `WebhookSender.swift` – `NotificationMessage`, `WebhookSender`, `WebhookError`, `LiveWebhookSender`.
- `NotificationService.swift` – `NotifyChannel`, `NotifyError`, channel resolution, sending.
- `NotificationPrefsService.swift` – user toggles, channel, webhook key.
- `EpisodeNotice.swift` – model + `NoticeKind`.
- `EpisodeNoticeService.swift` – `DueNotice`, due computation, record, cleanup.
- `NotificationTexts.swift` – digest, test and new-device texts.
- `NotificationPass.swift` – `runNotifications(...)`.

Modified: `Catalog/Episode.swift`, `Catalog/CatalogMigrations.swift`, `Catalog/CatalogService.swift`, `Catalog/DailyRefresh.swift`, `Tracking/UserTitle.swift`, `Tracking/TrackingMigrations.swift`, `Tracking/WatchService.swift`, `Auth/User.swift`, `Admin/UpdateCheck.swift` (AppSettings fields), `Mail/MailTexts.swift`, `API/DeviceNoticeService.swift`, `API/APIError.swift`, `Config/Application+Services.swift`, `configure.swift`, `Admin/SystemController.swift`, `Web/Pages/SystemPage.swift`, `Account/AccountController.swift`, `Web/Pages/AccountPage.swift`, `Sources/WatchSwiftyAPI/openapi.yaml`, new `API/APIHandler+Notifications.swift`, `Sources/WatchSwiftyClient/{openapi-generator-config.yaml,OpenValues.swift}`, `Package.swift`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`.

Tests (new): `NotifyScheduleTests`, `NotificationSettingsTests`, `WebhookSenderTests`, `NotificationServiceTests`, `EpisodeNoticeTests`, `NotificationTextsTests`, `NotificationPassTests`, `SystemNotificationsTests`, `AccountNotificationsTests`, `APINotificationsTests`; support `Tests/AppTests/Support/FakeWebhookSender.swift`.

---

### Task 1: Refresh token also from followers who hid the series (§1 bug)

**Files:**
- Modify: `Sources/App/Catalog/DailyRefresh.swift:18-24` (`refreshToken(for:on:cipher:)`)
- Test: `Tests/AppTests/DailyRefreshTests.swift`

**Interfaces:**
- Produces: unchanged signature `refreshToken(for titleID: UUID, on db: any Database, cipher: TokenCipher) async throws -> String?`; owners = user_titles of the title with `hidden == false` **or** `followed == true` (same rule as `seriesDueForRefresh`).

- [ ] **Step 1: Write the failing test**

```swift
@Test func refreshTokenFromFollowerWhoHidSeries() async throws {
    try await withTestApp { app in
        let pat = try await createUser(app, "pat", tmdbToken: "follower-token")
        let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
        let ws = WatchService(db: app.db)
        try await ws.setFollowed(userID: pat.requireID(), titleID: show.requireID(), followed: true)
        try await ws.setHidden(userID: pat.requireID(), titleID: show.requireID(), hidden: true)
        #expect(try await refreshToken(for: show.requireID(), on: app.db, cipher: app.tokenCipher) == "follower-token")
    }
}
```

- [ ] **Step 2: Run it, expect FAIL** — `swift test --filter "DailyRefreshTests/refreshTokenFromFollowerWhoHidSeries"` → returns `nil`.
- [ ] **Step 3: Change the owner query** to a `.group(.or)` of `hidden == false` / `followed == true`.
- [ ] **Step 4: Run `swift test --filter DailyRefreshTests`** → all PASS (including the existing `refreshToken` test at line ~80).
- [ ] **Step 5: Commit** — `fix(catalog): refresh followed series hidden from the library`

---

### Task 2: Seen times on episodes, follow time on library entries (§4 "Neue Daten")

**Files:**
- Modify: `Sources/App/Catalog/Episode.swift`, `Sources/App/Catalog/CatalogMigrations.swift`, `Sources/App/Catalog/CatalogService.swift` (`refresh`, `upsertEpisodes`), `Sources/App/Tracking/UserTitle.swift`, `Sources/App/Tracking/TrackingMigrations.swift`, `Sources/App/Tracking/WatchService.swift` (`setFollowed`), `Sources/App/configure.swift`
- Test: `Tests/AppTests/CatalogServiceTests.swift`, `Tests/AppTests/NewEpisodesTests.swift`

**Interfaces:**
- Produces:
  - `Episode.firstSeenAt: Date?` (`first_seen_at`), `Episode.lastSeenAt: Date?` (`last_seen_at`).
  - `extension Episode { func isCurrent(titleRefreshedAt: Date?) -> Bool }` — `lastSeenAt == nil || titleRefreshedAt == nil || lastSeenAt! >= titleRefreshedAt!`.
  - `UserTitle.followedAt: Date?` (`followed_at`).
  - `WatchService.setFollowed(userID: UUID, titleID: UUID, followed: Bool, now: Date = .now) async throws` — sets `followedAt = now` exactly when it sets `followedOn` today, `nil` on unfollow.
  - Migrations `AddEpisodeSeenTimes` (adds both columns, then one SQL statement `UPDATE episodes SET last_seen_at = (SELECT refreshed_at FROM titles WHERE titles.id = episodes.title_id)`), `AddFollowedAt`. Append in this order.

- [ ] **Step 1: Write the failing tests** (CatalogServiceTests; use the existing `FakeTMDBClient` series setup used there)

```swift
@Test func refreshStampsFirstAndLastSeen() async throws {
    // series with S1E1 cached; TMDB now returns S1E1 + S1E2
    // refresh(title, now: t1)
    #expect(e2.firstSeenAt == t1)            // newly inserted
    #expect(e1.firstSeenAt == nil)           // existed before (seeded)
    #expect(e1.lastSeenAt == t1 && e2.lastSeenAt == t1)
    #expect(e1.isCurrent(titleRefreshedAt: title.refreshedAt))
}

@Test func episodeMissingFromRefreshBecomesStale() async throws {
    // cached S1E1, S1E2; TMDB returns only S1E1; refresh(now: t2)
    #expect(e2.lastSeenAt != t2)
    #expect(!e2.isCurrent(titleRefreshedAt: t2))
    #expect(e1.isCurrent(titleRefreshedAt: t2))
}
```

NewEpisodesTests:

```swift
@Test func followStampsAndClearsFollowedAt() async throws {
    // setFollowed(true, now: t) → entry.followedAt == t; setFollowed(true, now: t+60) keeps t; setFollowed(false) → nil
}
```

- [ ] **Step 2: Run, expect FAIL** (missing members).
- [ ] **Step 3: Implement** fields, `isCurrent`, migrations; `upsertEpisodes(_:titleID:now:on:)` sets `firstSeenAt = now` on insert and afterwards one bulk update `Episode.query(on: db).filter(\.$title.$id == titleID).filter(\.$id ~~ returnedIDs).set(\.$lastSeenAt, to: now).update()`; `refresh` passes its `now` (same value as `title.refreshedAt`).
- [ ] **Step 4: Run `swift test`** → PASS (whole suite; migrations run in every test).
- [ ] **Step 5: Commit** — `feat(catalog): remember when episodes were first and last seen at TMDB`

---

### Task 3: Daily schedule and admin notification settings (§1, §3)

**Files:**
- Create: `Sources/App/Notify/DailySchedule.swift`, `Sources/App/Notify/NotificationSettingsService.swift`, `Sources/App/Notify/NotifyMigrations.swift`
- Modify: `Sources/App/Admin/UpdateCheck.swift` (AppSettings fields), `Sources/App/Config/Application+Services.swift`, `Sources/App/configure.swift`
- Test: `Tests/AppTests/NotifyScheduleTests.swift`, `Tests/AppTests/NotificationSettingsTests.swift`

**Interfaces:**
- Produces:
  - `AppSettings.dailyRunTime: String?` (`daily_run_time`, nil = default), `AppSettings.dailyRunAt: Date?` (`daily_run_at`), `AppSettings.webhookURL: String?` (`webhook_url`); migration `AddNotificationSettings`.
  - `enum DailySchedule { static let defaultTime = "07:00"; static func parse(_ raw: String) -> (hour: Int, minute: Int)?; static func nextRun(after now: Date, time: String, timeZone: TimeZone) -> Date; static func runsAtBoot(lastRun: Date?, now: Date) -> Bool }` — `parse` accepts `H:MM`/`HH:MM`, 0–23 / 0–59 (trimmed); `nextRun` uses `Calendar.nextDate(after:matching:matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)` with seconds 0, falling back to `defaultTime` for an unparsable stored value; `runsAtBoot` = `lastRun == nil || now.timeIntervalSince(lastRun!) > 86_400`.
  - `final class DailyRunTrigger: Sendable { func wake(); func sleep(until date: Date) async -> Bool }` — returns `true` when woken before `date`, `false` when the date was reached; also returns on task cancellation. A wake while nobody sleeps is kept until the next `sleep` (so a save during a pass is not lost).
  - `Application.dailyRunTrigger: DailyRunTrigger` (storage accessor, set in `configure` always).
  - `struct NotificationSettings: Equatable, Sendable { var dailyRunTime: String; var webhookURL: String?; var lastRunAt: Date? }`
  - `struct NotificationSettingsService { let db: any Database; var trigger: DailyRunTrigger? = nil; static let timeMessage = "Uhrzeit bitte als HH:MM angeben, z. B. 07:00."; static let webhookURLMessage = "Webhook-Adresse: z. B. https://knot.example.lan/hook – ohne Benutzer, ?… und #…."; func settings() async throws -> NotificationSettings; func save(dailyRunTime: String, webhookURL: String?) async throws -> NotificationSettings; func removeWebhook() async throws; func markRun(at: Date) async throws; static func webhookURL(_ raw: String) -> String? }` — `save` validates (empty/nil URL = remove), stores `HH:MM` zero-padded, calls `trigger?.wake()` after saving; `webhookURL` trims, requires `http`/`https`, non-empty host, no user/password, no query, no fragment (also reject raw `?`/`#`), path allowed, returns the trimmed string.
  - `Request.notificationSettings` / `Application.notificationSettings` (both with `trigger: application.dailyRunTrigger`).

- [ ] **Step 1: Write the failing tests**

```swift
// NotifyScheduleTests
@Test func nextRunLaterToday()        // now 06:00 Berlin, "07:00" → same day 07:00
@Test func nextRunTomorrowWhenPassed() // now 07:00:01 → next day 07:00
@Test func nextRunSkipsMissingDSTHour() // Europe/Berlin 2026-03-29 "02:30", now 2026-03-29 01:00 → 2026-03-29 03:00 (first existing moment), and only once
@Test func runsAtBootOnlyAfter24h()   // nil → true; 23 h ago → false; 25 h ago → true
@Test func parseTimes()               // "7:05"→(7,5), "07:00"→(7,0), "24:00"/"7:60"/"abc"/"" → nil
@Test func sleepReturnsEarlyOnWake() async   // sleep(until: now+60 s) woken after 50 ms → true, elapsed < 5 s
@Test func sleepReachesDate() async          // sleep(until: now+0.05 s) → false
@Test func wakeBeforeSleepIsKept() async     // wake(); sleep(until: now+60 s) → true at once

// NotificationSettingsTests
@Test func defaultsWithoutRow()       // settings() == NotificationSettings(dailyRunTime: "07:00", webhookURL: nil, lastRunAt: nil)
@Test func savesTimeAndURL()          // save("5:30", " https://knot.lan/hook ") → "05:30", "https://knot.lan/hook"
@Test func rejectsQueryUserInfoAndScheme() // "https://knot.lan/hook?apiKey=x", "https://u:p@knot.lan/hook", "ftp://knot.lan", "https://knot.lan/hook#x", "knot.lan" → APIError.validation(webhookURLMessage)
@Test func rejectsBadTime()           // "25:00" → APIError.validation(timeMessage)
@Test func emptyURLRemovesWebhook()
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run `swift test --filter "NotifyScheduleTests|NotificationSettingsTests"`** → PASS.
- [ ] **Step 5: Commit** — `feat(notify): daily run time and webhook address settings`

---

### Task 4: Webhook sender for KNot (§2)

**Files:**
- Create: `Sources/App/Notify/WebhookSender.swift`, `Tests/AppTests/Support/FakeWebhookSender.swift`
- Modify: `Package.swift` (dependency `.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0")`, product `AsyncHTTPClient` in target `App`), `Sources/App/Config/Application+Services.swift`, `Sources/App/configure.swift` (`webhookSender: (any WebhookSender)? = nil` parameter, default `LiveWebhookSender(userAgent: "WatchSwifty/\(config.appVersion.version)")`), `Tests/AppTests/Support/TestApp.swift` (`webhook: FakeWebhookSender = FakeWebhookSender()` passed through)
- Test: `Tests/AppTests/WebhookSenderTests.swift`

**Interfaces:**
- Produces:
  - `struct NotificationMessage: Sendable, Equatable { var subject: String; var body: String }`
  - `protocol WebhookSender: Sendable { func send(_ message: NotificationMessage, url: String, key: String) async throws }` — throws `WebhookError`.
  - `struct WebhookError: Error, Equatable, Sendable { let message: String; static let notConfigured; static let timeout; static func status(_ code: Int) -> WebhookError; static func connect(_ detail: String) -> WebhookError }` with these exact messages:
    - `notConfigured`: „Der Webhook ist nicht eingerichtet.“
    - `timeout`: „Der Webhook hat nicht rechtzeitig geantwortet.“
    - `connect`: „Webhook nicht erreichbar (\(detail)).“
    - `status(400)`: „KNot hat die Nachricht abgelehnt (400).“
    - `status(401)`: „KNot kennt den Webhook-Schlüssel nicht (401) – Schlüssel unter Konto prüfen.“
    - `status(413)`: „Die Nachricht ist für KNot zu groß (413).“
    - `status(429)`: „Zu viele Nachrichten an dieses KNot-Ziel (429) – später erneut versuchen.“
    - `status(502)`: „KNot konnte die Mail nicht zustellen (502) – Log von KNot prüfen.“
    - `status(300..<400)`: „Der Webhook leitet weiter (\(code)) – bitte die Adresse unter System prüfen.“
    - other: „Der Webhook hat mit Status \(code) geantwortet.“
  - `struct LiveWebhookSender: WebhookSender { let userAgent: String }` — one `HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(10), read: .seconds(60))))` per send, `execute(request, timeout: .seconds(60))`, body via `JSONEncoder` of `["subject": …, "body": …]`, 2xx = success, `try await client.shutdown()` in all paths. Connection errors → `connect(String(describing: error))` (never include the key); deadline → `timeout`.
  - `Application.webhookSender: any WebhookSender`.
  - Test support: `final class FakeWebhookSender: WebhookSender, @unchecked Sendable { struct Sent { let url: String; let key: String; let message: NotificationMessage }; var sent: [Sent]; var failure: WebhookError? }` (lock like `FakeMailSender`).

- [ ] **Step 1: Write the failing tests** — `WebhookSenderTests` runs a throwaway Vapor `Application` on `127.0.0.1`, port 0 (`app.server.start(address: .hostname("127.0.0.1", port: 0))`, port from `app.http.server.shared.localAddress`), routes `POST /hook` (records headers/body, returns 200), `POST /fail` (502), `POST /moved` (302 `Location: /hook`).

```swift
@Test func liveSenderPostsKNotFormat() async throws {
    // send(NotificationMessage(subject: "Betreff ä", body: "Zeile 1\nZeile 2"), url: "\(base)/hook", key: "k-1234567890abcdef")
    #expect(recorded.header("X-API-Key") == "k-1234567890abcdef")
    #expect(recorded.json == ["subject": "Betreff ä", "body": "Zeile 1\nZeile 2"])   // exactly these two keys
}
@Test func liveSenderMapsStatus() async throws   // /fail → WebhookError.status(502)
@Test func liveSenderDoesNotFollowRedirect() async throws // /moved → WebhookError.status(302); /hook recorded nothing
@Test func liveSenderUnreachable() async throws  // url "http://127.0.0.1:1/hook" → message starts with "Webhook nicht erreichbar"
@Test func errorMessages()                      // status(401/429/413/400/418) messages exactly as listed
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** sender, error, storage, configure/test wiring, fake.
- [ ] **Step 4: Run `swift test --filter WebhookSenderTests`** → PASS; then `swift test` → PASS.
- [ ] **Step 5: Commit** — `feat(notify): webhook sender for KNot`

---

### Task 5: Channels, preferences, delivery; „Neues Gerät“ through it (§5, §6)

**Files:**
- Create: `Sources/App/Notify/NotificationService.swift`, `Sources/App/Notify/NotificationPrefsService.swift`, `Sources/App/Notify/NotificationTexts.swift` (test + new-device texts only; digest in Task 7)
- Modify: `Sources/App/Auth/User.swift` (fields + `webhookKeyState`), `Sources/App/Notify/NotifyMigrations.swift` (`AddNotificationPrefs`), `Sources/App/configure.swift`, `Sources/App/API/DeviceNoticeService.swift`, `Sources/App/Mail/MailTexts.swift` (remove `newDevice`, moved)
- Test: `Tests/AppTests/NotificationServiceTests.swift`, existing `Tests/AppTests/DeviceNoticeTests.swift` stays green

**Interfaces:**
- Consumes: `NotificationMessage`, `WebhookSender`, `WebhookError` (Task 4); `NotificationSettingsService` (Task 3); `MailService`, `MailError`, `EmailState`.
- Produces:
  - `User` fields: `notifyChannel: String?` (`notify_channel`, nil = mail), `notifyAnnounced: Bool?`, `notifySoon: Bool?`, `notifyToday: Bool?` (`notify_announced`/`notify_soon`/`notify_today`, nil = off), `notifyAnnouncedSince: Date?` (`notify_announced_since`), `webhookKey: String?` (`webhook_key`, sealed).
  - `enum NotifyChannel: String, Codable, CaseIterable, Sendable { case mail, webhook }`; `User.preferredChannel: NotifyChannel` (nil/unknown → `.mail`).
  - `enum WebhookKeyState: Equatable, Sendable { case none, unreadable, key(String) }`; `User.webhookKeyState(_ cipher: TokenCipher) -> WebhookKeyState`.
  - `struct NotifyError: Error, Equatable, Sendable { let message: String; static let notConfigured = NotifyError(message: "Für dein Konto ist kein Versandweg eingerichtet.") }`
  - `struct NotificationService { let db: any Database; let cipher: TokenCipher; let mail: MailService; let webhook: any WebhookSender; let settings: NotificationSettingsService; let login: LoginSettings }` with
    - `func availableChannels(for user: User) async throws -> [NotifyChannel]` — `.mail` if `mail.settings.state().settings != nil` and `user.emailState(cipher)` is `.address`; `.webhook` if `settings.settings().webhookURL != nil` and the key state is `.key`. Order `[.mail, .webhook]`.
    - `func activeChannel(for user: User) async throws -> NotifyChannel?` — preferred if available, else the other if available, else nil.
    - `func send(_ message: NotificationMessage, to user: User) async throws -> NotifyChannel` — throws `NotifyError` (`MailError.message` / `WebhookError.message` wrapped; `.notConfigured` without a channel).
    - `func baseURL() async throws -> String?` — mail settings `baseURL`, else `login.oidc?.canonicalOrigin`.
  - `Request.notifications` / `Application.notifications`.
  - `struct NotificationPrefsService { let db: any Database; let hasher: AsyncPasswordHasher; let cipher: TokenCipher }` with
    - `func save(user: User, announced: Bool, soon: Bool, today: Bool, channel: NotifyChannel, available: [NotifyChannel], now: Date = .now) async throws` — 422 `APIError.validation("Dieser Versandweg ist für dein Konto nicht eingerichtet.")` when `!available.isEmpty && !available.contains(channel)`; sets `notifyAnnouncedSince = now` when announced goes from off to on.
    - `func setWebhookKey(user: User, key: String, currentPassword: String?) async throws` — accounts with a password: verify, else `APIError.validation(AccountValidation.wrongCurrentPasswordMessage)`; accounts without: no check. Empty (trimmed) key removes; otherwise 16…512 printable ASCII without spaces, else `APIError.validation("Der Schlüssel muss mindestens 16 Zeichen lang sein, ohne Leerzeichen.")`.
    - `Request.notificationPrefs`.
  - `enum NotificationTexts { static func test(username: String) -> NotificationMessage; static func newDevice(username: String, device: String, at date: Date, link: String?) -> NotificationMessage }` — `newDevice` keeps today's text (subject „WatchSwifty: Neues Gerät verbunden“, device name on one line) and omits the link line when `link == nil`; `test` subject „WatchSwifty: Testnachricht“.
  - `DeviceNoticeService` sends `NotificationTexts.newDevice(…, link: baseURL.map { "\($0)/account" })` through `NotificationService.send`; nothing (and no log) when no channel is available.

- [ ] **Step 1: Write the failing tests** (`NotificationServiceTests`, users built like `DeviceNoticeTests.user`, mail via `configureMail(app)`, webhook via `NotificationSettingsService.save`)

```swift
@Test func noChannelWithoutSetup()            // availableChannels == [], activeChannel == nil, send throws NotifyError.notConfigured
@Test func mailWhenAddressAndMailConfigured() // send → FakeMailSender.sent.count == 1, header Subject == message.subject; returns .mail
@Test func webhookWhenChosenAndKeySet()       // prefs channel .webhook, key set → FakeWebhookSender.sent[0].key == key, url == stored URL; mail untouched
@Test func fallsBackWhenPreferredMissing()    // preferred .webhook, admin removed URL → .mail used
@Test func webhookErrorIsWrapped()            // fake failure .status(401) → NotifyError(message: WebhookError.status(401).message)
@Test func keyNeedsCurrentPassword()          // wrong password → validation error, key unchanged; right password → stored sealed (raw column != key, webhookKeyState == .key(key))
@Test func keyWithoutPasswordForSSOOnlyAccount() // user without password: setWebhookKey(currentPassword: nil) stores it
@Test func rejectsShortOrSpacedKey()
@Test func savingUnavailableChannelFails()    // available [.mail], channel .webhook → 422
@Test func enablingAnnouncedStampsSince()     // off→on sets notifyAnnouncedSince == now; on→on keeps it
@Test func deviceNoticeGoesByWebhook()        // channel webhook + key → connecting an app sends one webhook with subject "WatchSwifty: Neues Gerät verbunden", no mail
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; move `newDevice` from `MailTexts` to `NotificationTexts`.
- [ ] **Step 4: Run `swift test --filter "NotificationServiceTests|DeviceNoticeTests"`** → PASS; then `swift test`.
- [ ] **Step 5: Commit** — `feat(notify): per-user channel and webhook key, new-device notice through it`

---

### Task 6: Which notices are due (§4)

**Files:**
- Create: `Sources/App/Notify/EpisodeNotice.swift`, `Sources/App/Notify/EpisodeNoticeService.swift`
- Modify: `Sources/App/Notify/NotifyMigrations.swift` (`CreateEpisodeNotice`), `Sources/App/configure.swift`
- Test: `Tests/AppTests/EpisodeNoticeTests.swift`

**Interfaces:**
- Consumes: `Episode.firstSeenAt/lastSeenAt/isCurrent`, `UserTitle.followedAt` (Task 2); `User.notify*` fields (Task 5).
- Produces:
  - `enum NoticeKind: String, Codable, CaseIterable, Sendable, Comparable { case announced, soon, today }` (order: today < soon < announced for display priority).
  - `final class EpisodeNotice: Model` — `episode_notices`: `id`, `user_id` (FK users, cascade), `episode_id` (FK episodes, cascade), `kind: String`, `air_date: String?`, `sent_at: Date`; unique (`user_id`, `episode_id`, `kind`). **Not** added to `titleUsers(on:)`.
  - `struct DueNotice: Equatable, Sendable { let episodeID: UUID; let tmdbEpisodeID: Int; let seriesTMDBID: Int; let seriesName: String; let season: Int; let number: Int; let name: String; let airDate: String?; let kinds: Set<NoticeKind>; var headline: NoticeKind { kinds.min()! } }`
  - `struct EpisodeNoticeService { let db: any Database }` with
    - `func due(for user: User, today: String) async throws -> [DueNotice]` — only the user's followed TV titles; only current episodes with `season >= 1`; per episode the set of due kinds (rules below); entries with an empty set dropped; sorted by series name, then season, number.
    - `func record(_ due: [DueNotice], userID: UUID, now: Date) async throws` — upsert one row per (episode, kind): insert, or update `air_date` + `sent_at` of the existing row.
    - `func cleanup(today: String) async throws -> Int` — delete notices whose episode's **current** `air_date` is more than 30 days before `today`; undated stay.
  - Due rules (exact):
    - `announced`: `user.notifyAnnounced == true`, `firstSeenAt != nil`, `firstSeenAt > max(followedAt ?? .distantPast, user.notifyAnnouncedSince ?? .distantPast)`, `airDate == nil || CalendarDay.daysBetween(airDate, today) <= 7`, and no `announced` row for this episode **or for any other episode of the same title with the same `tmdbEpisodeID`**.
    - `soon`: `user.notifySoon == true`, `airDate != nil`, `(1...3).contains(CalendarDay.daysBetween(today, airDate))`, no `soon` row with the same `air_date` for this episode or a same-`tmdbEpisodeID` sibling.
    - `today`: `user.notifyToday == true`, `airDate == today`, no `today` row with the same `air_date` (same sibling rule).

- [ ] **Step 1: Write the failing tests** (helpers: `follow(app, user, title, at:)` calls `setFollowed(now:)`; `seen(app, episode, at:)` sets `firstSeenAt`; `prefs(user, announced:soon:today:)` sets the fields directly; dates relative to `2026-11-07`)

```swift
@Test func announcedForEpisodeSeenAfterFollow()        // followed t0, E seen t1>t0, airDate nil → kinds == [.announced]
@Test func noAnnouncedForEpisodesKnownBeforeFollow()   // E seen t0 < followedAt → none
@Test func noAnnouncedForPreexistingRows()             // firstSeenAt nil → none
@Test func announcedSkipsOldAirDates()                 // airDate 2026-10-30 (8 days) → none; 2026-10-31 (7 days) → announced
@Test func announcedRespectsEnableTime()               // seen after follow but before notifyAnnouncedSince → none
@Test func soonWindowOneToThreeDays()                  // 2026-11-08/-10 → soon; 2026-11-07 and 2026-11-11 → not soon
@Test func todayOnAirDate()                            // 2026-11-07 → today; 2026-11-06 → nothing ("kein gestern")
@Test func announcedAndSoonInOneEntry()                // new episode airing 2026-11-09 → one DueNotice, kinds [.announced, .soon], headline .soon
@Test func recordedNoticesAreNotDueAgain()             // record(due) then due() → []
@Test func postponedEpisodeRemindsForNewDate()         // soon recorded for 2026-11-09, airDate moved to 2026-11-10 → soon due again; announced not
@Test func renumberedEpisodeNotAnnouncedTwice()        // announced recorded for row A (tmdbEpisodeID 42); new row B same title, same tmdbEpisodeID, seen later → no announced
@Test func staleRowGetsNoReminder()                    // row with lastSeenAt < title.refreshedAt and airDate today → none
@Test func specialsAndUnfollowedIgnored()              // season 0 → none; series not followed → none
@Test func onlyOwnFollows()                            // bob follows, pat doesn't → due(pat) == []
@Test func togglesOffMeansNothing()
@Test func cleanupUsesCurrentAirDate()                 // notice air_date 2026-09-01 but episode now 2026-12-24 → kept; episode 2026-10-07 → deleted (31 days); undated → kept
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** (read follows, titles, episodes, notices in a few queries per user; no per-episode queries).
- [ ] **Step 4: Run `swift test --filter EpisodeNoticeTests`** → PASS.
- [ ] **Step 5: Commit** — `feat(notify): compute due episode notices`

---

### Task 7: Digest text (§4 "Sammelnachricht")

**Files:**
- Modify: `Sources/App/Notify/NotificationTexts.swift`
- Test: `Tests/AppTests/NotificationTextsTests.swift`

**Interfaces:**
- Consumes: `DueNotice`, `NoticeKind` (Task 6), `NotificationMessage` (Task 4).
- Produces: `static func digest(username: String, items: [DueNotice], today: String, baseURL: String?) -> NotificationMessage`.
- Exact format (fixed so tests can assert it):
  - Subject: `"WatchSwifty: "` + non-empty parts joined by `", "` in the order today, soon, announced, counted by `headline`: `"1 Folge heute"` / `"\(n) Folgen heute"`, `"1 Folge in den nächsten Tagen"` / `"\(n) Folgen in den nächsten Tagen"`, `"\(n) neu angekündigt"`.
  - Body:

```
Hallo <username>,

neues zu deinen beobachteten Serien:

<Serie>
  Heute:
  S02E03 „<Name>“
  In den nächsten Tagen:
  S02E04 „<Name>“ – Di., 10.11.2026 (in 3 Tagen)
  Neu angekündigt:
  S03E01 „<Name>“ – Termin noch offen
  <baseURL>/tv/<tmdbID>

Die Termine sind die von TMDB – bei US-Serien oft einen Tag vor der Verfügbarkeit hier.
Abschalten unter „Konto → Benachrichtigungen“.

Viele Grüße
WatchSwifty
```

  - Series sorted by name (case-insensitive), a blank line between series; empty sections omitted; each episode once, in the section of its `headline`; date suffix: soon → `" – <EE, dd.MM.yyyy> (morgen)"` for 1 day, `"(in N Tagen)"` otherwise; announced with date → `" – <EE, dd.MM.yyyy>"`, without → `" – Termin noch offen"`; today → no date. Weekday `de_DE` `EE` (e.g. „Di.“). Link line only with `baseURL`. Series and episode names: control characters and line breaks replaced by spaces.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func subjectCountsByHeadline()   // 2 today, 5 announced → "WatchSwifty: 2 Folgen heute, 5 neu angekündigt"; 1 soon → "WatchSwifty: 1 Folge in den nächsten Tagen"
@Test func bodyGroupsBySeriesAndSection() // two series, "Andor" before "the Expanse"; sections in order Heute, In den nächsten Tagen, Neu angekündigt
@Test func dateSuffixes()             // "– So., 08.11.2026 (morgen)", "– Di., 10.11.2026 (in 3 Tagen)", "– Termin noch offen"
@Test func linkOnlyWithBaseURL()      // "https://watch.example.lan/tv/1399" present / absent
@Test func namesStayOnOneLine()       // name "A\nB" → "„A B“"
```

- [ ] **Step 2: Run, expect FAIL.** - [ ] **Step 3: Implement.** - [ ] **Step 4: Run `swift test --filter NotificationTextsTests`** → PASS.
- [ ] **Step 5: Commit** — `feat(notify): digest text for due episode notices`

---

### Task 8: Notification pass and scheduled daily run (§1, §4 "Versand")

**Files:**
- Create: `Sources/App/Notify/NotificationPass.swift`
- Modify: `Sources/App/Catalog/DailyRefresh.swift` (`DailyRefreshLifecycle`)
- Test: `Tests/AppTests/NotificationPassTests.swift`

**Interfaces:**
- Consumes: `EpisodeNoticeService` (6), `NotificationTexts.digest` (7), `NotificationService` (5), `NotificationSettingsService.markRun/settings`, `DailySchedule`, `DailyRunTrigger` (3).
- Produces:
  - `struct NotificationPassResult: Equatable, Sendable { var sent = 0; var failed = 0; var cleaned = 0 }`
  - `func runNotifications(db: any Database, notifications: NotificationService, today: String, now: Date = .now, logger: Logger) async -> NotificationPassResult` — users with at least one toggle on; per user: skip silently when `activeChannel(for:)` is nil (nothing recorded, so items wait until a channel exists); `due` → skip if empty → `digest(username:items:today:baseURL: notifications.baseURL())` → `send`; on success `record(due, userID:, now:)` and `sent += 1`; on `NotifyError` log warning `"Benachrichtigung für \(username) fehlgeschlagen: \(error.message)"` (no address, no key) and `failed += 1`; any other error per user is logged and does not stop the loop; finally `cleanup(today:)`.
  - `DailyRefreshLifecycle.didBootAsync`: the existing loop body moves into `func runDailyPass(_ application: Application, now: Date) async` (unchanged steps, first `markRun(at: now)`, last `runNotifications` with a summary log line `"Benachrichtigungen: \(sent) verschickt, \(failed) fehlgeschlagen"` when anything happened). Loop: if `DailySchedule.runsAtBoot(lastRun:now:)` → sleep 60 s, run; then forever: `next = DailySchedule.nextRun(after: .now, time: settings.dailyRunTime, timeZone: .current)`; `if await trigger.sleep(until: next) { continue }`; run.

- [ ] **Step 1: Write the failing tests** (users with mail + address via `configureMail`, follow + seen episodes as in Task 6)

```swift
@Test func oneDigestPerUser()               // pat: 3 due items in 2 series → FakeMailSender.sent.count == 1, result.sent == 1
@Test func sentItemsAreNotRepeated()        // run twice same day → second run sends nothing
@Test func failedSendIsRetriedNextDay()     // FakeMailSender.failure set → result.failed == 1, nothing recorded; clear failure, run again → sent, same items
@Test func oneFailureDoesNotStopOthers()    // pat by webhook (FakeWebhookSender.failure 502), bob by mail → bob gets his digest
@Test func usersWithoutTogglesAreSkipped()  // no send even with due episodes
@Test func usersWithoutChannelAreSkipped()  // toggles on, no channel → sent == 0, failed == 0, nothing recorded, no warning; next user served
@Test func cleanupRunsInPass()              // old notice deleted, result.cleaned == 1
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `runNotifications`, extract `runDailyPass`, new loop.
- [ ] **Step 4: Run `swift test --filter "NotificationPassTests|DailyRefreshTests|NotifyScheduleTests"`** → PASS; `swift test`.
- [ ] **Step 5: Commit** — `feat(notify): daily pass at the configured time sends due notices`

---

### Task 9: System → Benachrichtigungen (§3)

**Files:**
- Modify: `Sources/App/Admin/SystemController.swift`, `Sources/App/Web/Pages/SystemPage.swift`
- Test: `Tests/AppTests/SystemNotificationsTests.swift`

**Interfaces:**
- Consumes: `NotificationSettingsService` (3).
- Produces: routes (admin group, like `mail`) `POST /system/notifications` (form `dailyRunTime`, `webhookURL`), `POST /system/notifications/webhook/delete`. `SystemPage` gets `var notifications: NotificationsSection` with `settings: NotificationSettings`, `timeZone: String`, `nextRun: Date`, `form: (time: String, url: String)?` for re-showing rejected input.
- Section content (German): heading „Benachrichtigungen“; field „Täglicher Abgleich um“ (`input type=time`); line „Zeitzone des Servers: <TimeZone.current.identifier>“; when the identifier is `UTC`/`GMT`, the hint „Der Server läuft in UTC – im Container `TZ` setzen, z. B. `TZ=Europe/Berlin`.“; „Letzter Durchgang: <formatDateTime>“ (or „noch keiner“) and „Nächster: <formatDateTime>“; field „Webhook-Adresse (KNot)“ with placeholder `https://knot.example.lan/hook`; hint text naming KNot with a link to `https://github.com/nexus421/KNot`: KNot leitet Webhooks als Mail weiter; für jede Person in KNot ein eigenes Ziel mit ihrer Adresse anlegen, den Schlüssel mit `java -jar knot.jar key` erzeugen und weitergeben; sie trägt ihn unter „Konto → Benachrichtigungen“ ein; button „Webhook entfernen“ when set. Notices: „Benachrichtigungen gespeichert.“, „Webhook entfernt.“

- [ ] **Step 1: Write the failing tests**

```swift
@Test func adminSavesTimeAndWebhook()   // POST form → 200, notice text, settings() == ("05:30", "https://knot.lan/hook")
@Test func invalidURLShowsMessage()     // 422, body contains NotificationSettingsService.webhookURLMessage and keeps the entered values
@Test func pageShowsKNotLinkAndTimeZone() // GET /system contains "https://github.com/nexus421/KNot" and "Zeitzone des Servers"
@Test func nonAdminCannotSave()         // regular user → same status as other System posts (403)
@Test func removeWebhook()
```

- [ ] **Step 2: Run, expect FAIL.** - [ ] **Step 3: Implement.** - [ ] **Step 4: Run `swift test --filter SystemNotificationsTests`** → PASS.
- [ ] **Step 5: Commit** — `feat(system): notification time and KNot webhook settings`

---

### Task 10: Konto → Benachrichtigungen (§5)

**Files:**
- Modify: `Sources/App/Account/AccountController.swift`, `Sources/App/Web/Pages/AccountPage.swift`
- Test: `Tests/AppTests/AccountNotificationsTests.swift`

**Interfaces:**
- Consumes: `NotificationService`, `NotificationPrefsService`, `NotificationTexts.test` (5), `NotificationSettingsService` (3).
- Produces: routes `POST /account/notifications` (form `announced`, `soon`, `today` checkboxes, `channel`), `POST /account/notifications/webhook-key` (`key`, `currentPassword`), `POST /account/notifications/webhook-key/remove` (`currentPassword`), `POST /account/notifications/test`. `AccountPage` gets `var notifications: AccountNotifications` (toggles, `available: [NotifyChannel]`, `active: NotifyChannel?`, `preferred`, `webhookConfigured: Bool`, `keyState: WebhookKeyState`, `dailyRunTime: String`, `needsPassword: Bool`).
- Section content: heading „Benachrichtigungen“; „Neue Folgen beobachteter Serien“ with checkboxes „sobald eine neue Folge bekannt wird“, „3 Tage vor der Ausstrahlung“, „am Tag der Ausstrahlung“ and the line „Geprüft wird täglich um <HH:MM> Uhr.“; „Senden per“: radio buttons only for `available` (labels „E-Mail“, „Webhook (KNot)“), one available → plain text, none → hint „Noch kein Versandweg: hinterlege eine Mail-Adresse oder einen Webhook-Schlüssel – oder der Admin hat den Versand noch nicht eingerichtet.“; key block only when `webhookConfigured`: password field „Webhook-Schlüssel (KNot)“, „gespeichert“ when set, „Schlüssel nicht lesbar – bitte neu eintragen“ when unreadable, „Aktuelles Passwort“ when `needsPassword`, button „Schlüssel entfernen“, hint „Den Schlüssel bekommst du vom Admin.“; button „Testnachricht senden“ (disabled text when `active == nil`). Notices: „Benachrichtigungen gespeichert.“, „Webhook-Schlüssel gespeichert.“, „Webhook-Schlüssel entfernt.“, „Testnachricht gesendet.“; send errors shown with `NotifyError.message` and status 503.
- „Neues Gerät verbunden“ needs no UI (always on).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func savesToggles()                     // POST announced=on&today=on&channel=mail → user.notifyAnnounced == true, notifySoon == false
@Test func channelChoiceOnlyWhenBothAvailable() // GET /account: both → two radios; mail only → no radio "webhook"
@Test func keyIsNeverShownAgain()             // after saving, page contains "gespeichert" and not the key
@Test func keyWithWrongPasswordFails()        // 422 + AccountValidation.wrongCurrentPasswordMessage
@Test func testNotificationGoesOut()          // POST test → FakeWebhookSender/FakeMailSender got subject "WatchSwifty: Testnachricht"
@Test func testFailureShowsMessage()          // fake failure → 503, message in body
@Test func keyBlockHiddenWithoutWebhook()
```

- [ ] **Step 2: Run, expect FAIL.** - [ ] **Step 3: Implement.** - [ ] **Step 4: Run `swift test --filter AccountNotificationsTests`** → PASS.
- [ ] **Step 5: Commit** — `feat(account): notification settings and webhook key`

---

### Task 11: App API (§7)

**Files:**
- Modify: `Sources/WatchSwiftyAPI/openapi.yaml`, `Sources/App/API/APIError.swift`, `Sources/WatchSwiftyClient/openapi-generator-config.yaml`, `Sources/WatchSwiftyClient/OpenValues.swift`
- Create: `Sources/App/API/APIHandler+Notifications.swift`
- Test: `Tests/AppTests/APINotificationsTests.swift`

**Interfaces:**
- Consumes: services from Tasks 3 and 5.
- Produces:
  - Paths (tags `Account` / `Admin`, `bearerAuth`): `GET/PUT /v1/me/notifications` (operationIds `getNotificationPrefs`, `setNotificationPrefs`), `PUT/DELETE /v1/me/notifications/webhook-key` (`setWebhookKey`, `deleteWebhookKey`), `POST /v1/me/notifications/test` (`sendTestNotification`, 204), `GET/PUT /v1/admin/notifications` (`getNotificationSettings`, `setNotificationSettings`).
  - Schemas: `NotifyChannel` (enum `mail`, `webhook`); `NotificationPrefs` (required `announced`, `soon`, `today` bool, `channel` NotifyChannel, `availableChannels` [NotifyChannel], `webhookConfigured` bool, `hasWebhookKey` bool, `dailyRunTime` string; optional `activeChannel` NotifyChannel); `NotificationPrefsUpdate` (`announced`, `soon`, `today`, `channel`); `WebhookKeyChange` (`key`, optional `currentPassword`); `WebhookKeyRemove` (optional `currentPassword`); `AdminNotificationSettings` (required `dailyRunTime`, `timeZone`, `nextRunAt` date-time; optional `webhookUrl`, `lastRunAt`); `AdminNotificationSettingsUpdate` (`dailyRunTime`, optional `webhookUrl` – missing or empty removes).
  - Responses: new component `NotifyFailed` (503, `notifyFailed`). `APIError.notificationsNotConfigured` (422, code `notificationsNotConfigured`, message `NotifyError.notConfigured.message`) and `APIError.notifyFailed(_ message: String)` (503); `APIError.from` maps `NotifyError` → `notificationsNotConfigured` when it equals `.notConfigured`, else `notifyFailed`; `WebhookError` → `notifyFailed`.
  - Client: `typeOverrides.schemas.NotifyChannel: NotifyChannelValue`, `NotifyChannelValue` in `OpenValues.swift` with `.mail`, `.webhook`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func prefsRoundTrip()          // PUT {announced:true,soon:false,today:true,channel:"mail"} → GET reflects it; availableChannels == ["mail"]
@Test func keyNeverInResponse()      // PUT webhook-key → body has hasWebhookKey true and does not contain the key
@Test func keyNeedsPassword()        // wrong currentPassword → 422 validation
@Test func testWithoutChannel()      // POST test → 422 notificationsNotConfigured
@Test func testWebhookFailure()      // fake 502 → 503 notifyFailed, message == WebhookError.status(502).message
@Test func adminSettings()           // admin PUT {dailyRunTime:"06:15", webhookUrl:"https://knot.lan/hook"} → GET same, timeZone == TimeZone.current.identifier
@Test func adminOnly()               // non-admin GET /v1/admin/notifications → 403
```

- [ ] **Step 2: Run, expect FAIL** (operations missing → build error).
- [ ] **Step 3: Edit `openapi.yaml`, implement handlers** (call only the shared services), APIError cases, client override.
- [ ] **Step 4: Run `swift build` and `swift test --filter "APINotificationsTests|APIDocsTests"`** → PASS; `swift test`.
- [ ] **Step 5: Commit** — `feat(api): notification preferences and settings`

---

### Task 12: Docs (§8)

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `CLAUDE.md`

- [ ] **Step 1: README** — new section „Benachrichtigungen (optional)“: what is reported (three kinds, followed series, one digest per day), daily time under System and `TZ` in the container, KNot setup (link, one target per person, `java -jar knot.jar key`, address under System, key under Konto), TMDB date caveat for US series, „Neues Gerät“ follows the chosen channel.
- [ ] **Step 2: CHANGELOG** — under `## [Unveröffentlicht]`: `### Neu` (Benachrichtigungen zu neuen Folgen per Mail oder KNot-Webhook; Uhrzeit des täglichen Abgleichs wählbar; App-API-Endpunkte), `### Behoben` (beobachtete, aber ausgeblendete Serien wurden nicht aktualisiert).
- [ ] **Step 3: CLAUDE.md** — add `Notify` to the feature folder list; note that `episode_notices` deliberately does not count in `titleUsers(on:)`.
- [ ] **Step 4: Run `swift test`** → PASS.
- [ ] **Step 5: Commit** — `docs: notifications and KNot webhook`
