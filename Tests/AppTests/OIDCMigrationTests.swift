@testable import App
import ConsoleKit
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("OIDCMigration")
struct OIDCMigrationTests {
    @Test func migrationAddsColumnsAndIndex() async throws {
        try await withTestApp { app in
            let first = try await createUser(app, "anna")
            first.oidcIssuer = "https://id.example.test"
            first.oidcSubject = "s1"
            try await first.save(on: app.db)
            let reloaded = try #require(try await User.find(first.requireID(), on: app.db))
            #expect(reloaded.oidcIssuer == "https://id.example.test")
            #expect(reloaded.oidcSubject == "s1")

            let second = try await createUser(app, "bert")
            second.oidcIssuer = "https://id.example.test"
            second.oidcSubject = "s1"
            await #expect(throws: (any Error).self) { try await second.save(on: app.db) }
        }
    }

    @Test func samePairAllowedForOtherIssuer() async throws {
        try await withTestApp { app in
            let first = try await createUser(app, "anna")
            first.oidcIssuer = "https://old.example"
            first.oidcSubject = "s1"
            try await first.save(on: app.db)
            let second = try await createUser(app, "bert")
            second.oidcIssuer = "https://id.example.test"
            second.oidcSubject = "s1"
            try await second.save(on: app.db)
        }
    }

    @Test func nullPairsDoNotCollide() async throws {
        try await withTestApp { app in
            try await createUser(app, "anna")
            try await createUser(app, "bert")
            #expect(try await User.query(on: app.db).count() == 3)   // + bootstrap admin
        }
    }

    @Test func migrationReverts() async throws {
        try await withTestApp { app in
            try await app.autoRevert()
            try await app.autoMigrate()
            try await createUser(app, "anna")
        }
    }

    @Test func linkTokenIssueCheckConsume() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            let service = OIDCLinkTokenService(db: app.db)
            let token = try await service.issue(userID: user.requireID(), lifetime: OIDCLinkTokenService.commandLifetime)
            #expect(token.count >= 43)
            #expect(try await service.check(token) != nil)
            #expect(try await service.consume(token) == user.id)
            #expect(try await service.consume(token) == nil)
            #expect(try await service.check(token) == nil)
        }
    }

    @Test func linkTokenStoredOnlyAsHash() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            let token = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 60)
            let record = try #require(try await OIDCLinkToken.query(on: app.db).first())
            #expect(record.tokenHash == APITokenService.hash(token))
            #expect(record.tokenHash != token)
        }
    }

    @Test func linkTokenReplacesOlder() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            let service = OIDCLinkTokenService(db: app.db)
            let first = try await service.issue(userID: user.requireID(), lifetime: 60)
            let second = try await service.issue(userID: user.requireID(), lifetime: 60)
            #expect(try await service.check(first) == nil)
            #expect(try await service.check(second) != nil)
        }
    }

    @Test func expiredLinkTokenInvalidAndCleaned() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            let service = OIDCLinkTokenService(db: app.db)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let token = try await service.issue(userID: user.requireID(), lifetime: 60, now: start)
            #expect(try await service.check(token, now: start.addingTimeInterval(59)) != nil)
            #expect(try await service.check(token, now: start.addingTimeInterval(61)) == nil)
            #expect(try await service.consume(token, now: start.addingTimeInterval(61)) == nil)
            #expect(try await service.deleteExpired(now: start.addingTimeInterval(61)) == 1)
            #expect(try await OIDCLinkToken.query(on: app.db).count() == 0)
        }
    }

    @Test func linkTokensGoWithTheUser() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "anna")
            _ = try await OIDCLinkTokenService(db: app.db).issue(userID: user.requireID(), lifetime: 60)
            try await user.delete(on: app.db)
            #expect(try await OIDCLinkToken.query(on: app.db).count() == 0)
        }
    }

    @Test func userHelpers() throws {
        let oidc = try #require(AppConfig.testingOIDC.oidc)
        let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
        #expect(!user.isLinked(oidc))
        user.oidcIssuer = "https://id.example.test/"
        #expect(!user.isLinked(oidc))   // subject missing
        user.oidcSubject = "s1"
        #expect(user.isLinked(oidc))
        #expect(!user.isLinked(nil))
        user.oidcIssuer = "https://old.example"
        #expect(!user.isLinked(oidc))
        user.oidcIssuer = "https://id.example.test"

        // Without password: SSO account and address from the provider, whatever PASSWORD_LOGIN says.
        #expect(user.isSSOAccount(oidc, passwordLogin: true))
        #expect(user.isSSOAccount(oidc, passwordLogin: false))
        #expect(user.emailFromProvider(oidc))
        // With password: SSO account only without password login; address stays manual.
        user.passwordHash = "$2b$04$hash"
        #expect(!user.isSSOAccount(oidc, passwordLogin: true))
        #expect(user.isSSOAccount(oidc, passwordLogin: false))
        #expect(!user.emailFromProvider(oidc))
        // Not linked: never.
        #expect(!user.isSSOAccount(nil, passwordLogin: false))
        #expect(!user.emailFromProvider(nil))
    }

    // MARK: - Issuer move (Task 14)

    private func linked(_ app: Application, _ name: String, subject: String, issuer: String) async throws -> User {
        let user = try await createUser(app, name)
        user.oidcIssuer = issuer
        user.oidcSubject = subject
        try await user.save(on: app.db)
        return user
    }

    private func service(_ app: Application) throws -> OIDCLoginService {
        OIDCLoginService(db: app.db, cipher: app.tokenCipher, oidc: AppConfig.testingOIDC.oidc!, passwordLogin: true,
                         lock: app.oidcIdentityLock)
    }

    @Test func moveIssuerRewritesAll() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let anna = try await linked(app, "anna", subject: "s1", issuer: "https://old.example/app/")
            let bert = try await linked(app, "bert", subject: "s2", issuer: "https://old.example/app")
            let other = try await linked(app, "carl", subject: "s3", issuer: "https://elsewhere.example")
            let moved = try await service(app).moveIssuer(from: "https://old.example/app", to: "https://id.example.test")
            #expect(moved == 2)
            #expect(try await User.find(anna.id, on: app.db)?.oidcIssuer == "https://id.example.test")
            #expect(try await User.find(bert.id, on: app.db)?.oidcIssuer == "https://id.example.test")
            #expect(try await User.find(other.id, on: app.db)?.oidcIssuer == "https://elsewhere.example")
            #expect(try await User.find(anna.id, on: app.db)?.isLinked(AppConfig.testingOIDC.oidc) == true)
        }
    }

    @Test func moveIssuerConflictChangesNothing() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let anna = try await linked(app, "anna", subject: "s1", issuer: "https://old.example")
            _ = try await linked(app, "bert", subject: "s2", issuer: "https://old.example")
            _ = try await linked(app, "carl", subject: "s1", issuer: "https://id.example.test")
            await #expect(throws: APIError.self) {
                _ = try await service(app).moveIssuer(from: "https://old.example", to: "https://id.example.test")
            }
            #expect(try await User.find(anna.id, on: app.db)?.oidcIssuer == "https://old.example")
            #expect(try await User.query(on: app.db).filter(\.$oidcIssuer == "https://old.example").count() == 2)
        }
    }

    @Test func moveIssuerUnknownOldIsNoop() async throws {
        try await withTestApp(config: .testingOIDC) { app in
            let moved = try await service(app).moveIssuer(from: "https://nothing.example", to: "https://id.example.test")
            #expect(moved == 0)
        }
    }

    private func runMove(_ app: Application, _ arguments: [String]) async throws -> ScriptedConsole {
        let console = ScriptedConsole(answers: [])
        var context = CommandContext(console: console, input: CommandInput(arguments: ["App", "oidc-move-issuer"] + arguments))
        context.application = app
        try await app.asyncCommands.group().run(using: &context)
        return console
    }

    @Test func moveIssuerCommand() async throws {
        let fake = FakeOIDCProvider()
        fake.issuer = "https://id.example.test/"
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            _ = try await linked(app, "anna", subject: "s1", issuer: "https://old.example")
            let console = try await runMove(app, ["https://old.example", "https://id.example.test"])
            #expect(console.printed.contains("1 Konto auf https://id.example.test umgestellt."))
            #expect(console.printed.contains("Achtung: Die Discovery nennt den Issuer https://id.example.test/"))
        }
    }

    @Test func moveIssuerCommandWithoutOIDCFails() async throws {
        try await withTestApp { app in
            await #expect(throws: CommandFailure.self) { _ = try await runMove(app, ["https://a.example", "https://b.example"]) }
        }
    }

    @Test func reenablingOIDCRestoresLinks() async throws {
        let fake = FakeOIDCProvider()
        try await withTestApp { app in
            let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
            try await user.save(on: app.db)
            user.oidcIssuer = OIDCTestKeys.issuer
            user.oidcSubject = "sub-1"
            try await user.save(on: app.db)
            #expect(!user.isLinked(app.loginSettings.current.oidc))
            #expect(try await app.userAdmin.row(for: user).invite == .expired)
        }
        try await withTestApp(config: .testingOIDC, oidc: fake) { app in
            let user = User(username: "anna", passwordHash: User.noPasswordHash, isAdmin: false)
            try await user.save(on: app.db)
            user.oidcIssuer = OIDCTestKeys.issuer
            user.oidcSubject = "sub-1"
            try await user.save(on: app.db)
            let flow = try await oidcFlow(app, fake)
            #expect(flow.location == "/")
        }
    }
}
