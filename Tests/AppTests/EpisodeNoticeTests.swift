@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Shared helpers for notice tests (today is 2026-11-07).
enum NoticeFixture {
    static let today = "2026-11-07"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let t1 = t0.addingTimeInterval(3600)
    static let t2 = t0.addingTimeInterval(7200)

    static func follow(_ app: Application, _ user: User, _ title: Title, at: Date = t0) async throws {
        try await WatchService(db: app.db).setFollowed(userID: user.requireID(), titleID: title.requireID(), followed: true, now: at)
    }

    static func seen(_ app: Application, _ title: Title, _ season: Int, _ number: Int, at: Date = t1) async throws {
        let ep = try await episode(app, title, season, number)
        ep.firstSeenAt = at
        try await ep.save(on: app.db)
    }

    static func prefs(_ app: Application, _ user: User, announced: Bool = false, soon: Bool = false, today: Bool = false,
                      since: Date? = nil) async throws {
        user.notifyAnnounced = announced
        user.notifySoon = soon
        user.notifyToday = today
        user.notifyAnnouncedSince = since
        try await user.save(on: app.db)
    }

    static func due(_ app: Application, _ user: User) async throws -> [DueNotice] {
        try await EpisodeNoticeService(db: app.db).due(for: user, today: today)
    }
}

@Suite("EpisodeNotice")
struct EpisodeNoticeTests {
    typealias F = NoticeFixture

    func codes(_ due: [DueNotice]) -> [String] { due.map { "\($0.season)x\($0.number)" } }

    @Test func announcedForEpisodeSeenAfterFollow() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], noAirDate: ["1x1"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.prefs(app, pat, announced: true)
            let due = try await F.due(app, pat)
            #expect(codes(due) == ["1x1"])
            #expect(due.first?.kinds == [.announced])
            #expect(due.first?.airDate == nil)
        }
    }

    @Test func noAnnouncedForEpisodesKnownBeforeFollow() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 8], noAirDate: Set((1...8).map { "1x\($0)" }))
            for n in 1...8 { try await F.seen(app, show, 1, n, at: F.t0.addingTimeInterval(-60)) }
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, announced: true)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func noAnnouncedForPreexistingRows() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], noAirDate: ["1x1"])
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, announced: true)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func announcedSkipsOldAirDates() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], airDates: ["1x1": "2026-10-30", "1x2": "2026-10-31"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.seen(app, show, 1, 2)
            try await F.prefs(app, pat, announced: true)
            #expect(codes(try await F.due(app, pat)) == ["1x2"])
        }
    }

    @Test func announcedRespectsEnableTime() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], noAirDate: ["1x1"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1, at: F.t1)
            try await F.prefs(app, pat, announced: true, since: F.t2)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func soonWindowOneToThreeDays() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 4], airDates: [
                "1x1": "2026-11-07", "1x2": "2026-11-08", "1x3": "2026-11-10", "1x4": "2026-11-11"])
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, soon: true)
            let due = try await F.due(app, pat)
            #expect(codes(due) == ["1x2", "1x3"])
            #expect(due.allSatisfy { $0.kinds == [.soon] })
        }
    }

    @Test func todayOnAirDate() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], airDates: ["1x1": "2026-11-06", "1x2": "2026-11-07"])
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, today: true)
            let due = try await F.due(app, pat)
            #expect(codes(due) == ["1x2"])
            #expect(due.first?.kinds == [.today])
        }
    }

    @Test func announcedAndSoonInOneEntry() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-09"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.prefs(app, pat, announced: true, soon: true)
            let due = try await F.due(app, pat)
            #expect(due.count == 1)
            #expect(due.first?.kinds == [.announced, .soon])
            #expect(due.first?.headline == .soon)
        }
    }

    @Test func recordedNoticesAreNotDueAgain() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], airDates: ["1x1": "2026-11-09", "1x2": "2026-11-07"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.prefs(app, pat, announced: true, soon: true, today: true)
            let due = try await F.due(app, pat)
            #expect(due.count == 2)
            try await EpisodeNoticeService(db: app.db).record(due, userID: pat.requireID(), now: F.t2)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func postponedEpisodeRemindsForNewDate() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-09"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.prefs(app, pat, announced: true, soon: true)
            try await EpisodeNoticeService(db: app.db).record(try await F.due(app, pat), userID: pat.requireID(), now: F.t2)
            let ep = try await episode(app, show, 1, 1)
            ep.airDate = "2026-11-10"
            try await ep.save(on: app.db)
            let due = try await F.due(app, pat)
            #expect(due.first?.kinds == [.soon])
            #expect(due.first?.airDate == "2026-11-10")
        }
    }

    @Test func renumberedEpisodeNotAnnouncedTwice() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], noAirDate: ["1x1"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            try await F.prefs(app, pat, announced: true)
            try await EpisodeNoticeService(db: app.db).record(try await F.due(app, pat), userID: pat.requireID(), now: F.t2)
            // TMDB moved the episode to S2E1 (same TMDB id): the old row is no longer returned.
            let old = try await episode(app, show, 1, 1)
            old.lastSeenAt = F.t0
            try await old.save(on: app.db)
            let moved = Episode(titleID: try show.requireID(), season: 2, number: 1, name: "Verschoben", airDate: nil,
                                tmdbEpisodeID: old.tmdbEpisodeID)
            moved.firstSeenAt = F.t2
            moved.lastSeenAt = F.t2
            try await moved.save(on: app.db)
            show.refreshedAt = F.t2
            try await show.save(on: app.db)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func renumberedKnownEpisodeNotAnnounced() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            // S1E1 was cached before the update (no first-seen time) and before the follow.
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], noAirDate: ["1x1"])
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, announced: true)
            let old = try await episode(app, show, 1, 1)
            old.lastSeenAt = F.t0
            try await old.save(on: app.db)
            let moved = Episode(titleID: try show.requireID(), season: 2, number: 1, name: "Verschoben", airDate: nil,
                                tmdbEpisodeID: old.tmdbEpisodeID)
            moved.firstSeenAt = F.t2
            moved.lastSeenAt = F.t2
            try await moved.save(on: app.db)
            show.refreshedAt = F.t2
            try await show.save(on: app.db)
            #expect(try await F.due(app, pat).isEmpty)
            // Same when the old row was first seen before the follow.
            old.firstSeenAt = F.t0.addingTimeInterval(-60)
            try await old.save(on: app.db)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func staleRowGetsNoReminder() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-07"])
            show.refreshedAt = F.t2
            try await show.save(on: app.db)
            let ep = try await episode(app, show, 1, 1)
            ep.lastSeenAt = F.t1
            try await ep.save(on: app.db)
            try await F.follow(app, pat, show)
            try await F.prefs(app, pat, today: true)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func specialsAndUnfollowedIgnored() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let followed = try await seedSeries(app, tmdbID: 1, seasons: [0: 1], airDates: ["0x1": "2026-11-07"])
            let other = try await seedSeries(app, tmdbID: 2, seasons: [1: 1], airDates: ["1x1": "2026-11-07"])
            try await F.follow(app, pat, followed)
            try await WatchService(db: app.db).setHidden(userID: pat.requireID(), titleID: other.requireID(), hidden: false)
            try await F.prefs(app, pat, today: true)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func followedButHiddenCounts() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-07"])
            try await F.follow(app, pat, show)
            try await WatchService(db: app.db).setHidden(userID: pat.requireID(), titleID: show.requireID(), hidden: true)
            try await F.prefs(app, pat, today: true)
            #expect(codes(try await F.due(app, pat)) == ["1x1"])
        }
    }

    @Test func onlyOwnFollows() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let bob = try await createUser(app, "bobby")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-07"])
            try await F.follow(app, bob, show)
            try await F.prefs(app, pat, announced: true, soon: true, today: true)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func togglesOffMeansNothing() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1], airDates: ["1x1": "2026-11-07"])
            try await F.follow(app, pat, show)
            try await F.seen(app, show, 1, 1)
            #expect(try await F.due(app, pat).isEmpty)
        }
    }

    @Test func sortedBySeriesThenEpisode() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let zulu = try await seedSeries(app, tmdbID: 1, name: "Zulu", seasons: [1: 2], airDates: ["1x1": "2026-11-07", "1x2": "2026-11-07"])
            let alpha = try await seedSeries(app, tmdbID: 2, name: "alpha", seasons: [2: 1], airDates: ["2x1": "2026-11-07"])
            try await F.follow(app, pat, zulu)
            try await F.follow(app, pat, alpha)
            try await F.prefs(app, pat, today: true)
            #expect(try await F.due(app, pat).map { "\($0.seriesName) \($0.season)x\($0.number)" } == ["alpha 2x1", "Zulu 1x1", "Zulu 1x2"])
        }
    }

    @Test func cleanupUsesCurrentAirDate() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 4], noAirDate: ["1x3"],
                                            airDates: ["1x1": "2026-12-24", "1x2": "2026-10-07", "1x4": "2026-10-08"])
            for n in 1...4 {
                let ep = try await episode(app, show, 1, n)
                try await EpisodeNotice(userID: pat.requireID(), episodeID: ep.requireID(), kind: .announced,
                                        airDate: n == 1 ? "2026-09-01" : ep.airDate, sentAt: F.t0).save(on: app.db)
            }
            #expect(try await EpisodeNoticeService(db: app.db).cleanup(today: F.today) == 1)
            let left = try await EpisodeNotice.query(on: app.db).with(\.$episode).all().map { $0.episode.number }.sorted()
            #expect(left == [1, 3, 4])
        }
    }
}
