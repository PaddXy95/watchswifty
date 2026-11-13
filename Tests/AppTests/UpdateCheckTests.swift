@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct UpdateToggleForm: Content { var enabled: String? }

@Suite("UpdateCheck")
struct UpdateCheckTests {
    static var releaseConfig: AppConfig {
        var config = AppConfig.testing
        config.appVersion = AppVersion(version: "0.1.0", commit: nil)
        return config
    }

    func service(_ app: Application, _ fetcher: FakeReleaseFetcher, current: String = "0.1.0") -> UpdateService {
        UpdateService(db: app.db, fetcher: fetcher, current: AppVersion(version: current, commit: nil), status: app.updateStatus)
    }

    @Test func versionComparison() {
        #expect(isNewerVersion("0.1.3", than: "0.1.0") == true)
        #expect(isNewerVersion("v0.2.0", than: "0.1.9") == true)
        #expect(isNewerVersion("1.0.0", than: "0.9.12") == true)
        #expect(isNewerVersion("0.1.0", than: "0.1.0") == false)
        #expect(isNewerVersion("0.1.0", than: "0.1.2") == false)
        #expect(isNewerVersion("0.1.3", than: "dev") == nil)
        #expect(isNewerVersion("kaputt", than: "0.1.0") == nil)
    }

    @Test func decodesLatestRelease() throws {
        let json = #"{"tag_name":"v0.1.3","html_url":"https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3","name":"v0.1.3"}"#
        #expect(try LiveReleaseFetcher.decode(Data(json.utf8))
                == LatestRelease(version: "0.1.3", url: "https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3"))
        #expect(throws: ReleaseCheckError.self) { try LiveReleaseFetcher.decode(Data("{}".utf8)) }
    }

    @Test func checkStoresLatestRelease() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(releases: fetcher) { app in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let settings = try await service(app, fetcher).checkNow(now: now)
            #expect(settings.latestVersion == "0.1.3")
            #expect(settings.latestURL == "https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3")
            #expect(settings.checkedAt == now)
            #expect(settings.checkError == nil)
            #expect(app.updateStatus.newerVersion == "0.1.3")

            let upToDate = try await service(app, fetcher, current: "0.1.3").checkNow()
            #expect(upToDate.latestVersion == "0.1.3")
            #expect(app.updateStatus.newerVersion == nil)
        }
    }

    @Test func checkFailureKeepsLastResult() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(releases: fetcher) { app in
            _ = try await service(app, fetcher).checkNow()
            fetcher.failure = .notFound
            let settings = try await service(app, fetcher).checkNow()
            #expect(settings.latestVersion == "0.1.3")
            #expect(settings.checkError == ReleaseCheckError.notFound.message)
            #expect(ReleaseCheckError.notFound.message.contains("Kein Release gefunden"))
        }
    }

    @Test func dueOnlyWhenEnabledAndStale() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(releases: fetcher) { app in
            let updates = service(app, fetcher)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(try await updates.checkIfDue(now: now) == false)   // off by default: GitHub is never asked
            #expect(fetcher.calls == 0)

            try await updates.setEnabled(true)
            #expect(try await updates.checkIfDue(now: now) == true)
            #expect(try await updates.checkIfDue(now: now.addingTimeInterval(3600)) == false)
            #expect(try await updates.checkIfDue(now: now.addingTimeInterval(12 * 3600)) == true)
            #expect(fetcher.calls == 2)
        }
    }

    @Test func systemPageIsAdminOnly() async throws {
        try await withTestApp(config: Self.releaseConfig) { app in
            try await createUser(app, "chef", isAdmin: true)
            try await createUser(app, "pat")
            let admin = try await login(app, "chef")
            let user = try await login(app, "pat")
            try await app.testing().test(.GET, "/admin/system", headers: user) { res async in
                #expect(res.status == .forbidden)
            }
            try await app.testing().test(.GET, "/admin/system", headers: admin) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains(#"<a href="/admin/system" class="active" aria-current="page">System</a>"#))
                #expect(body.contains("api.github.com"))
                #expect(body.contains("Jetzt prüfen"))
                #expect(body.contains("Noch nicht geprüft."))
                #expect(!body.contains(#"name="enabled" checked"#))   // off by default
            }
        }
    }

    @Test func enablingChecksImmediately() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(config: Self.releaseConfig, releases: fetcher) { app in
            try await createUser(app, "chef", isAdmin: true)
            let admin = try await login(app, "chef")
            try await app.testing().test(.POST, "/admin/system/update-check", headers: admin, beforeRequest: { req in
                try req.content.encode(UpdateToggleForm(enabled: "on"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Automatische Prüfung eingeschaltet."))
                #expect(res.body.string.contains(#"name="enabled" checked"#))
            })
            #expect(fetcher.calls == 1)
            #expect(try await AppSettings.query(on: app.db).first()?.updateCheck == true)

            try await app.testing().test(.POST, "/admin/system/update-check", headers: admin, beforeRequest: { req in
                try req.content.encode(UpdateToggleForm(enabled: nil), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains("Automatische Prüfung ausgeschaltet."))
            })
            #expect(fetcher.calls == 1)
            #expect(try await AppSettings.query(on: app.db).first()?.updateCheck == false)
        }
    }

    @Test func checkNowShowsUpdateCommands() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(config: Self.releaseConfig, releases: fetcher) { app in
            try await createUser(app, "chef", isAdmin: true)
            let admin = try await login(app, "chef")
            try await app.testing().test(.POST, "/admin/system/check-now", headers: admin) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("Neue Version v0.1.3 verfügbar"))
                #expect(body.contains(#"href="https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.3""#))
                #expect(body.contains("docker compose pull &amp;&amp; docker compose up -d"))
                #expect(body.contains("Zuletzt geprüft:"))
            }
            #expect(fetcher.calls == 1)
        }
    }

    @Test func footerShowsUpdateToAdminsOnly() async throws {
        let fetcher = FakeReleaseFetcher()
        try await withTestApp(config: Self.releaseConfig, releases: fetcher) { app in
            try await createUser(app, "chef", isAdmin: true)
            try await createUser(app, "pat")
            _ = try await UpdateService(db: app.db, fetcher: fetcher, current: Self.releaseConfig.appVersion,
                                        status: app.updateStatus).checkNow()
            let admin = try await login(app, "chef")
            let user = try await login(app, "pat")
            try await app.testing().test(.GET, "/library", headers: admin) { res async in
                #expect(res.body.string.contains(#"<a href="/admin/system?open=updates" class="update-hint">Update auf v0.1.3 verfügbar</a>"#))
            }
            try await app.testing().test(.GET, "/library", headers: user) { res async in
                #expect(!res.body.string.contains("update-hint"))
            }
        }
    }
}
