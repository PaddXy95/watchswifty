@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct UserSummaryBody: Codable { let id: UUID; let username: String; let isAdmin: Bool; let hasTMDBToken: Bool }
struct NewUserBody: Content { var username: String; var password: String; var isAdmin: Bool }
struct AdminPasswordBody: Content { var password: String }
struct AdminFlagBody: Content { var isAdmin: Bool }

@Suite("APIAdmin")
struct APIAdminTests {
    func admin(_ app: Application) async throws -> (User, String) {
        let chef = try await createUser(app, "chef", isAdmin: true, tmdbToken: "secret-tmdb-token")
        return (chef, try await apiToken(app, chef))
    }

    @Test func nonAdminForbidden() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/admin/users", headers: .bearer(token)) { res async throws in
                #expect(res.status == .forbidden)
                #expect(try res.content.decode(APIErrorBody.self).code == "forbidden")
            }
        }
    }

    @Test func createUserValidation() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NewUserBody(username: "Neu", password: "passwort12", isAdmin: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                #expect(try res.content.decode(UserSummaryBody.self).username == "neu")
            })
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NewUserBody(username: "neu", password: "passwort12", isAdmin: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == AccountValidation.duplicateMessage)
            })
            try await app.testing().test(.POST, "/api/v1/admin/users", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(NewUserBody(username: "kurz", password: "kurz", isAdmin: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(APIErrorBody.self).message == AccountValidation.passwordMessage)
            })
        }
    }

    @Test func selfActionsRefused() async throws {
        try await withTestApp { app in
            let (chef, token) = try await admin(app)
            let id = try chef.requireID()
            try await app.testing().test(.PUT, "/api/v1/admin/users/\(id)/password", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(AdminPasswordBody(password: "neuespasswort"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).code == "selfAction")
            })
            try await app.testing().test(.PUT, "/api/v1/admin/users/\(id)/admin", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(AdminFlagBody(isAdmin: false), as: .json)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(APIErrorBody.self).code == "selfAction")
            })
            try await app.testing().test(.DELETE, "/api/v1/admin/users/\(id)", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(APIErrorBody.self).code == "selfAction")
            }
            #expect(try await User.find(id, on: app.db)?.isAdmin == true)
        }
    }

    @Test func adminActionsOnOthers() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            let pat = try await createUser(app, "pat")
            try await app.testing().test(.PUT, "/api/v1/admin/users/\(try pat.requireID())/admin", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(ConfirmedAdminFlagBody(isAdmin: true, currentPassword: "password123"), as: .json)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(UserSummaryBody.self).isAdmin == true)
            })
            try await app.testing().test(.PUT, "/api/v1/admin/users/\(try pat.requireID())/password", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(ConfirmedPasswordBody(password: "neuespasswort", currentPassword: "password123"), as: .json)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            _ = try await login(app, "pat", password: "neuespasswort")
            try await app.testing().test(.DELETE, "/api/v1/admin/users/\(try pat.requireID())", headers: .bearer(token)) { res async in
                #expect(res.status == .noContent)
            }
            #expect(try await User.find(pat.requireID(), on: app.db) == nil)
        }
    }

    @Test func listNeverShowsTokens() async throws {
        try await withTestApp { app in
            let (_, token) = try await admin(app)
            try await app.testing().test(.GET, "/api/v1/admin/users", headers: .bearer(token)) { res async throws in
                #expect(!res.body.string.contains("secret-tmdb-token"))
                let users = try res.content.decode([UserSummaryBody].self)
                #expect(users.first { $0.username == "chef" }?.hasTMDBToken == true)
            }
        }
    }
}
