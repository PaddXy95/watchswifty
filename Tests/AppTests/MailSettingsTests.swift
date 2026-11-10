@testable import App
import Crypto
import Fluent
import Testing
import VaporTesting

func mailInput(host: String = "relay.test", port: String? = "2525", encryption: String = "starttls",
               username: String? = "watchswifty", password: String? = "relay-secret",
               fromAddress: String = "noreply@example.org", fromName: String? = "", caFile: String? = "",
               baseURL: String = "https://watch.example.lan") -> MailSettingsInput {
    MailSettingsInput(host: host, port: port, encryption: encryption, username: username, password: password,
                      fromAddress: fromAddress, fromName: fromName, caFile: caFile, baseURL: baseURL)
}

@Suite("MailSettings")
struct MailSettingsTests {
    func service(_ app: Application) -> MailSettingsService {
        MailSettingsService(db: app.db, cipher: app.tokenCipher)
    }

    @Test func savesEncrypted() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput(port: "", username: "watchswifty", caFile: ""))
            let raw = try await AppSettings.query(on: app.db).first()?.mailConfig ?? ""
            #expect(raw.hasPrefix("enc:v1:"))
            #expect(!raw.contains("relay-secret"))
            #expect(!raw.contains("relay.test"))
            let settings = try #require(try await service(app).state().settings)
            #expect(settings.host == "relay.test")
            #expect(settings.port == nil)
            #expect(settings.effectivePort == 587)
            #expect(settings.encryption == .starttls)
            #expect(settings.username == "watchswifty")
            #expect(settings.password == "relay-secret")
            #expect(settings.fromName == "WatchSwifty")
            #expect(settings.caFile == nil)
            try await service(app).save(mailInput(username: "", password: ""))
            #expect(try await service(app).state().settings?.username == nil)
        }
    }

    @Test func blankPasswordKeepsStored() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput())
            try await service(app).save(mailInput(password: "", fromName: "Serien"))
            let settings = try await service(app).state().settings
            #expect(settings?.password == "relay-secret")
            #expect(settings?.fromName == "Serien")
        }
    }

    @Test func connectionChangeNeedsPassword() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput())
            for changed in [mailInput(host: "evil.test", password: ""), mailInput(port: "25", password: ""),
                            mailInput(encryption: "plain", password: ""), mailInput(username: "other", password: "")] {
                await #expect(throws: APIError.validation(MailSettingsService.passwordReentryMessage)) {
                    try await service(app).save(changed)
                }
            }
            #expect(try await service(app).state().settings?.host == "relay.test")
            try await service(app).save(mailInput(host: "new.test", password: "new-secret"))
            #expect(try await service(app).state().settings?.password == "new-secret")
        }
    }

    @Test func missingPasswordForUsername() async throws {
        try await withTestApp { app in
            await #expect(throws: APIError.validation(MailSettingsService.passwordMissingMessage)) {
                try await service(app).save(mailInput(password: ""))
            }
        }
    }

    @Test func noUsernameNoPassword() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput(host: "other.test", username: "", password: ""))
            #expect(try await service(app).state().settings?.host == "other.test")
            #expect(try await service(app).state().settings?.password == nil)
        }
    }

    /// A password without a user used to be dropped silently: saved as „eingerichtet“, sent without login.
    @Test func passwordWithoutUsernameRejected() async throws {
        try await withTestApp { app in
            await #expect(throws: APIError.validation(MailSettingsService.passwordWithoutUserMessage)) {
                try await service(app).save(mailInput(username: "", password: "relay-secret"))
            }
            let state = try await service(app).state()
            #expect(state == .notConfigured)
        }
    }

    @Test func baseURLNormalized() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput(baseURL: "https://watch.example.lan/"))
            let settings = try #require(try await service(app).state().settings)
            #expect(settings.baseURL == "https://watch.example.lan")
            #expect(settings.link(token: "abc") == "https://watch.example.lan/reset-password?token=abc")
            try await service(app).save(mailInput(password: "", baseURL: "http://nas.lan:8080"))
            #expect(try await service(app).state().settings?.baseURL == "http://nas.lan:8080")
            for bad in ["https://x/app", "https://x?a=1", "https://x#a", "ftp://x", "watch.lan", ""] {
                await #expect(throws: APIError.validation(MailSettingsService.baseURLMessage), "\(bad)") {
                    try await service(app).save(mailInput(baseURL: bad))
                }
            }
        }
    }

    @Test func invalidFieldsRejected() async throws {
        try await withTestApp { app in
            await #expect(throws: APIError.validation(MailSettingsService.hostMessage)) {
                try await service(app).save(mailInput(host: " "))
            }
            for port in ["0", "70000", "abc"] {
                await #expect(throws: APIError.validation(MailSettingsService.portMessage)) {
                    try await service(app).save(mailInput(port: port))
                }
            }
            await #expect(throws: APIError.validation(EmailAddress.invalidMessage)) {
                try await service(app).save(mailInput(fromAddress: "x"))
            }
            await #expect(throws: APIError.self) {
                try await service(app).save(mailInput(encryption: "tls13"))
            }
            let state = try await service(app).state()
            #expect(state == .notConfigured)
        }
    }

    @Test func unreadableWithOtherKey() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput())
            let other = MailSettingsService(db: app.db, cipher: TokenCipher(key: SymmetricKey(size: .bits256)))
            #expect(try await other.state() == MailSettingsState.unreadable)
            #expect(try await other.state().settings == nil)
        }
    }

    @Test func deleteRemoves() async throws {
        try await withTestApp { app in
            try await service(app).save(mailInput())
            try await service(app).delete()
            #expect(try await service(app).state() == MailSettingsState.notConfigured)
        }
    }
}
