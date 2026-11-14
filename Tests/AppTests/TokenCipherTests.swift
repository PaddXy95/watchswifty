@testable import App
import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@Suite("TokenCipher")
struct TokenCipherTests {
    let cipher = TokenCipher(key: SymmetricKey(size: .bits256))
    let logger = Logger(label: "test")

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watchswifty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sealOpenRoundTrip() throws {
        let sealed = try cipher.seal("eyJsecret-token-abcd")
        #expect(sealed.hasPrefix("enc:v1:"))
        #expect(!sealed.contains("secret"))
        #expect(try cipher.seal("eyJsecret-token-abcd") != sealed)
        #expect(cipher.open(sealed) == "eyJsecret-token-abcd")
    }

    @Test func openWithWrongKeyIsNil() throws {
        let sealed = try cipher.seal("x-token")
        #expect(TokenCipher(key: SymmetricKey(size: .bits256)).open(sealed) == nil)
        #expect(cipher.open("enc:v1:kaputt") == nil)
    }

    @Test func openLegacyPlaintext() {
        #expect(cipher.open("plain-token") == "plain-token")
        #expect(cipher.open(nil) == nil)
        #expect(cipher.open("") == nil)
    }

    @Test func keyFromEnvironmentValue() throws {
        let raw = Data(repeating: 7, count: 32)
        let key = try TokenKeyLoader.load(key: raw.base64EncodedString(), file: nil, databasePath: "/nonexistent/db.sqlite", logger: logger)
        #expect(key.withUnsafeBytes { Data($0) } == raw)
        #expect(throws: ConfigError.self) {
            try TokenKeyLoader.load(key: "zu-kurz", file: nil, databasePath: ":memory:", logger: logger)
        }
    }

    @Test func keyFromFile() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = Data(repeating: 9, count: 32)
        let file = dir.appendingPathComponent("secret")
        try Data((raw.base64EncodedString() + "\n").utf8).write(to: file)
        let key = try TokenKeyLoader.load(key: nil, file: file.path, databasePath: ":memory:", logger: logger)
        #expect(key.withUnsafeBytes { Data($0) } == raw)
        #expect(throws: ConfigError.self) {
            try TokenKeyLoader.load(key: nil, file: dir.appendingPathComponent("fehlt").path, databasePath: ":memory:", logger: logger)
        }
    }

    @Test func generatedKeyFileIsReused() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("watchswifty.sqlite").path
        let first = try TokenKeyLoader.load(key: nil, file: nil, databasePath: database, logger: logger)
        let second = try TokenKeyLoader.load(key: nil, file: nil, databasePath: database, logger: logger)
        #expect(first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) })
        let keyFile = dir.appendingPathComponent("token.key").path
        let permissions = try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func plaintextTokensEncryptedOnBoot() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat", tmdbToken: "plain-token-1234")
            _ = try await createUser(app, "ohne", tmdbToken: nil)
            #expect(try await encryptStoredTokens(db: app.db, cipher: app.tokenCipher) == 1)
            let stored = try await User.find(user.requireID(), on: app.db)?.tmdbToken
            #expect(stored?.hasPrefix("enc:v1:") == true)
            #expect(app.tokenCipher.open(stored) == "plain-token-1234")
            #expect(try await encryptStoredTokens(db: app.db, cipher: app.tokenCipher) == 0)
        }
    }

    @Test func backgroundJobsGetDecryptedToken() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, runtime: 136))
        let tokens = NIOLockedValueBox<[String]>([])
        let provider = TMDBProvider { token in
            tokens.withLockedValue { $0.append(token) }
            return tmdb
        }
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("secret-token"))
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await WatchService(db: app.db).setHidden(userID: user.requireID(), titleID: show.requireID(), hidden: false)
            #expect(try await refreshTokens(for: show.requireID(), on: app.db, cipher: app.tokenCipher).first == "secret-token")

            let movie = try await seedMovie(app, tmdbID: 603)
            try await Watch(userID: user.requireID(), titleID: movie.requireID(), episodeID: nil, watchedOn: nil,
                            service: nil, origin: .manual).save(on: app.db)
            #expect(try await backfillTokens(for: movie.requireID(), on: app.db, cipher: app.tokenCipher).first == "secret-token")
            _ = await backfillDetails(db: app.db, provider: provider, cipher: app.tokenCipher, logger: app.logger)
            #expect(tokens.withLockedValue { $0 } == ["secret-token"])
        }
    }

    @Test func unreadableTokenTreatedAsMissing() async throws {
        try await withTestApp { app in
            let foreign = TokenCipher(key: SymmetricKey(size: .bits256))
            _ = try await createUser(app, "pat", tmdbToken: try foreign.seal("old-token"))
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/search?q=Matrix", headers: headers) { res async in
                #expect(res.body.string.contains("Für die Suche brauchst du einen eigenen TMDB-Token"))
            }
            try await app.testing().test(.GET, "/account", headers: headers) { res async in
                #expect(res.body.string.contains("Token nicht lesbar – bitte neu eintragen"))
            }
        }
    }
}
