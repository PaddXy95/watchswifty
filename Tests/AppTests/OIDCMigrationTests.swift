@testable import App
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
}
