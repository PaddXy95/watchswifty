import Fluent
import Foundation
import Vapor

/// Account logic of the OIDC login, shared by web, API and commands (spec „Konto bestimmen“ ff.).
struct OIDCLoginService {
    let db: any Database
    let cipher: TokenCipher
    let oidc: OIDCConfig
    let passwordLogin: Bool
    let lock: AsyncMutex

    /// The account linked with this identity (issuer compared without a trailing slash).
    func account(for identity: OIDCIdentity) async throws -> User? {
        let candidates = try await User.query(on: db).filter(\.$oidcSubject == identity.subject).all()
        return candidates.first { user in
            user.oidcIssuer.map(OIDCConfig.trimmed) == OIDCConfig.trimmed(identity.issuer)
        }
    }
}

extension Request {
    /// Only valid while OIDC is configured.
    var oidcLogin: OIDCLoginService {
        get throws {
            guard let oidc = application.appConfig.oidc else { throw Abort(.notFound) }
            return OIDCLoginService(db: db, cipher: application.tokenCipher, oidc: oidc,
                                    passwordLogin: application.appConfig.passwordLogin, lock: application.oidcIdentityLock)
        }
    }
}
