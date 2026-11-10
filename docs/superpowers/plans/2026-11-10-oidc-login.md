# OIDC-Login (SSO) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Login, account linking and migration via any OpenID Connect provider, as specified in the OIDC design.

**Architecture:** A small OIDC client on top of `jwt-kit` (`LiveOIDCProvider` behind the `OIDCProvider` protocol, faked in
tests), an encrypted short-lived flow cookie instead of session rows, and one service (`OIDCLoginService`) holding the
account logic for web, API and commands. Existing services (`AccountService`, `UserAdminService`, auth controllers)
learn two settings: `AppConfig.oidc` and `AppConfig.passwordLogin`.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, `jwt-kit` ≥ 5.8.0,
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-07-oidc-login-design.md` (section names below refer to it).

## Global Constraints

- Everything user-visible is German and taken verbatim from the spec (error table, page texts); `{name}` =
  `OIDCConfig.displayName` (default `SSO`). Code and comments English. Commits: English Conventional Commits.
- `.package(url: "https://github.com/vapor/jwt-kit.git", from: "5.8.0")`, product `JWTKit` in target `App` only.
- Allowed ID-token algorithms: RS256, RS384, RS512, PS256, PS384, PS512, ES256, ES384, ES512, EdDSA. Clock leeway 60 s.
- Time windows: flow cookie 10 min, parked identity 10 min, reauth 5 min, link token via command 3600 s, via admin
  7 × 86 400 s, discovery cache 24 h, JWKS reload at most once per 60 s.
- Cookie `watchswifty_oidc`: `HttpOnly`, `SameSite=Lax`, `Path=/auth/oidc`, `Max-Age=600`, `Secure` iff the canonical
  origin is https; value = `TokenCipher.seal(JSON)`.
- Account key is (issuer, subject); "linked" = OIDC configured ∧ `OIDCConfig.matchesIssuer(user.oidcIssuer)` ∧
  subject set.
- New migrations go at the end of the list in `configure.swift`; one `update()` per added field (SQLite).
- Every new per-request rule lives in a service shared by web and API (CLAUDE.md "Two front doors").
- API for disabled password login: `409` code `passwordLoginDisabled`; web pages that vanish: `404`.
- Codes, tokens and link URLs never appear in logs or error messages.
- Baseline before this plan: `swift test` → 554 tests in 108 suites pass.

## Review Focus

1. **TLS-terminating proxy:** a request reaches WatchSwifty as plain http with `Host` = canonical host and no
   `X-Forwarded-Proto` → must not redirect (no loop); canonical check compares authority only. Test in Task 5.
2. **Callback without cookie** (crawler, old bookmark, `error` param without cookie) → login page with
   „Anmeldung abgelaufen – bitte erneut versuchen.“, status 400, never 500. Test in Task 5.
3. **Double submit of „Konto anlegen“** → second POST signs in to the account just created, no duplicate, no 500.
   Test in Task 6.
4. **`aud` as a plain string and `email` with capitals/whitespace** → accepted, address normalized. Tests in Task 3
   and Task 6.
5. **Non-ASCII names** (`preferred_username` „jörg“, `name` „Jörg Müller“) → suggestion stripped to a valid name or
   empty, page renders. Test in Task 6.

---

### Task 1: Configuration

**Files:**
- Create: `Sources/App/Auth/OIDC/OIDCConfig.swift`
- Modify: `Sources/App/Config/AppConfig.swift` (fields `oidc`, `passwordLogin`; `fromEnvironment` rules)
- Modify: `Sources/App/Auth/OriginCheckMiddleware.swift` (make host matching reusable)
- Test: `Tests/AppTests/OIDCConfigTests.swift`, `Tests/AppTests/Support/TestApp.swift`

**Interfaces:**
- Produces: `struct OIDCConfig: Sendable, Equatable { issuer, clientID, clientSecret: String; redirectURL: URL;
  displayName: String; var canonicalOrigin: String; func matchesIssuer(_ stored: String?) -> Bool;
  static func fromEnvironment(_ env: [String: String], publicOrigins: [String]) throws -> OIDCConfig? }`
- Produces: `AppConfig.oidc: OIDCConfig?` (default `nil`), `AppConfig.passwordLogin: Bool` (default `true`).
- Produces: `static func OriginCheckMiddleware.requestMatches(origin: String, _ request: Request) -> Bool` (the former
  private `matchesRequestHost`, unchanged behaviour).
- Produces (tests): `static var AppConfig.testingOIDC: AppConfig` = `.testing` + `oidc = OIDCConfig(issuer:
  "https://id.example.test", clientID: "watchswifty", clientSecret: "secret", redirectURL:
  URL(string: "http://localhost:8080/auth/oidc/callback")!, displayName: "SSO")`.

- [ ] **Step 1: Failing tests** in `OIDCConfigTests` (`@Suite("OIDCConfig")`), all via `AppConfig.fromEnvironment`:
  - `completeConfigEnablesOIDC`: `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `PUBLIC_ORIGIN=https://watch.example.de`
    → `oidc?.displayName == "SSO"`, `redirectURL.absoluteString == "https://watch.example.de/auth/oidc/callback"`,
    `canonicalOrigin == "https://watch.example.de"`.
  - `partialConfigFails`: only `OIDC_ISSUER` → throws `ConfigError`.
  - `explicitRedirectWins`: `OIDC_REDIRECT_URL=https://w.example.de/auth/oidc/callback` → `canonicalOrigin == "https://w.example.de"`.
  - `missingRedirectAndOriginFails`.
  - `secretFromFile` (temp file with `"s3cret\n"` → `clientSecret == "s3cret"`), `unreadableSecretFileFails`.
  - `passwordLoginOffWithoutOIDCFails`: `PASSWORD_LOGIN=false` alone → throws; with full OIDC → `passwordLogin == false`.
  - `issuerMatchIgnoresTrailingSlash`: issuer `https://a/app/` matches `"https://a/app"` and `"https://a/app/"`, not `nil` or `"https://b/"`.
- [ ] **Step 2:** `swift test --filter OIDCConfig` → FAIL (types missing).
- [ ] **Step 3:** Implement. `PASSWORD_LOGIN` is false only for the literal `false` (case-insensitive). Error texts
  German, e.g. „OIDC unvollständig: OIDC_ISSUER, OIDC_CLIENT_ID und OIDC_CLIENT_SECRET (oder _FILE) gehören zusammen.“,
  „OIDC braucht OIDC_REDIRECT_URL oder PUBLIC_ORIGIN.“, „PASSWORD_LOGIN=false geht nur mit vollständiger
  OIDC-Konfiguration.“ Add `AppConfig.testingOIDC`.
- [ ] **Step 4:** `swift test --filter OIDCConfig` → PASS; `swift test --filter Config` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): configuration from the environment`.

### Task 2: Data model, migrations, link tokens

**Files:**
- Modify: `Sources/App/Auth/User.swift` (fields + helpers)
- Create: `Sources/App/Auth/OIDC/OIDCMigrations.swift` (`AddUserOIDC`, `CreateOIDCLinkToken`)
- Create: `Sources/App/Auth/OIDC/OIDCLinkToken.swift` (model + `OIDCLinkTokenService`)
- Modify: `Sources/App/configure.swift` (append both migrations), `Sources/App/Catalog/DailyRefresh.swift` (cleanup)
- Test: `Tests/AppTests/OIDCMigrationTests.swift`

**Interfaces:**
- Produces on `User`: `@OptionalField(key: "oidc_issuer") var oidcIssuer: String?`,
  `@OptionalField(key: "oidc_subject") var oidcSubject: String?`, `func isLinked(_ oidc: OIDCConfig?) -> Bool`,
  `func isSSOAccount(_ oidc: OIDCConfig?, passwordLogin: Bool) -> Bool` (linked ∧ ¬(hasPassword ∧ passwordLogin)),
  `func emailFromProvider(_ oidc: OIDCConfig?) -> Bool` (linked ∧ ¬hasPassword).
- Produces: `final class OIDCLinkToken: Model` (schema `oidc_link_tokens`: `id`, `user_id` → users cascade,
  `token_hash` unique, `created_at`, `expires_at`).
- Produces: `struct OIDCLinkTokenService { let db: any Database; static let commandLifetime: TimeInterval = 3600;
  static let adminLifetime: TimeInterval = 7 * 86_400; func issue(userID: UUID, lifetime: TimeInterval, now: Date = .now) async throws -> String;
  func check(_ token: String, now: Date = .now) async throws -> OIDCLinkToken?; func consume(_ token: String, now: Date = .now) async throws -> UUID?;
  func deleteExpired(now: Date = .now) async throws -> Int }` — token = 32 random bytes Base64URL (reuse `base64URL`),
  stored as `APITokenService.hash`, `issue` deletes older tokens of the user.

- [ ] **Step 1: Failing tests** (`@Suite("OIDCMigration")`, `withTestApp`):
  - `migrationAddsColumnsAndIndex`: save user with issuer `i`/subject `s`; a second user with the same pair → save throws.
  - `nullPairsDoNotCollide`: two users without OIDC save fine.
  - `migrationReverts`: `try await app.autoRevert()` succeeds (index dropped before columns).
  - `linkTokenIssueCheckConsume`: `issue` → `check` non-nil → `consume` returns the user id → second `consume` nil.
  - `linkTokenReplacesOlder`: second `issue` for the same user → first token's `check` is nil.
  - `expiredLinkTokenInvalidAndCleaned`: `issue(…, lifetime: 60, now: t)`; `check(now: t+61)` nil; `deleteExpired(now: t+61) == 1`.
  - `userHelpers`: with `AppConfig.testingOIDC.oidc` — unlinked user `isLinked == false`; issuer `https://id.example.test/`
    + subject → `isLinked`; other issuer → not linked; `nil` config → not linked; `isSSOAccount` / `emailFromProvider`
    truth table for (hasPassword, passwordLogin).
- [ ] **Step 2:** `swift test --filter OIDCMigration` → FAIL.
- [ ] **Step 3:** Implement. Index via `(database as? any SQLDatabase)` like `Episode.swift`:
  `CREATE UNIQUE INDEX users_oidc_identity ON users (oidc_issuer, oidc_subject)`; revert `DROP INDEX
  users_oidc_identity` first. DailyRefresh: after the password-token cleanup, log „\(n) abgelaufene
  Verknüpfungslinks gelöscht“.
- [ ] **Step 4:** `swift test --filter OIDCMigration` → PASS; `swift test --filter DailyRefresh` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): user identity columns and link tokens`.

### Task 3: ID-token validation

**Files:**
- Modify: `Package.swift` (jwt-kit)
- Create: `Sources/App/Auth/OIDC/OIDCIdentity.swift` (`OIDCIdentity`, `OIDCError`)
- Create: `Sources/App/Auth/OIDC/OIDCTokenValidator.swift`
- Create: `Tests/AppTests/Support/OIDCTestKeys.swift` (key + token helpers), Test: `Tests/AppTests/OIDCTokenValidatorTests.swift`

**Interfaces:**
- Produces: `struct OIDCIdentity: Codable, Sendable, Equatable { issuer, subject: String; preferredUsername, email, name: String? }`.
- Produces: `enum OIDCError: Error, Equatable { case unreachable, denied, failed(logReason: String), symmetricSigning,
  misconfigured(logReason: String), unknownKey(kid: String?); func message(name: String) -> String }` — messages from
  the spec's error table (`unknownKey`, `failed`, `misconfigured` → „Anmeldung über {name} fehlgeschlagen.“,
  `symmetricSigning` likewise plus the log hint).
- Produces: `struct OIDCTokenValidator { static let allowedAlgorithms: Set<String>; func validate(_ idToken: String,
  keys: JWTKeyCollection, issuer: String, clientID: String, nonce: String, now: Date) async throws -> OIDCIdentity }`.
- Produces (tests): `OIDCTestKeys.es256() -> (keys: JWTKeyCollection, jwks: String)` (kid `k1`),
  `OIDCTestKeys.rs256()` (fixed 2048-bit PEM, kid `r1`), `OIDCTestKeys.token(_ claims: TestIDToken, keys:, kid:) async throws -> String`,
  `struct TestIDToken: JWTPayload` (iss, sub, aud, exp, iat, nonce, azp, preferred_username, email, name).

- [ ] **Step 1: Failing tests** (`@Suite("OIDCTokenValidator")`), defaults iss `https://id.example.test`, aud
  `watchswifty`, nonce `n1`, now = fixed date:
  - `validES256TokenYieldsIdentity` → identity with sub/email/preferred username; `validRS256TokenYieldsIdentity`.
  - `audienceAsPlainString` (Review Focus 4) → accepted.
  - `wrongIssuerRejected`, `foreignAudienceRejected`, `multipleAudiencesNeedAzp` (aud `[watchswifty, other]` without azp → reject; with azp `watchswifty` → accept).
  - `expiredTokenRejected` (now = exp + 61 s), `expiryWithinLeewayAccepted` (exp + 59 s), `futureIatRejected` (iat = now + 120 s).
  - `nonceMismatchRejected`, `missingNonceRejected`.
  - `hs256Rejected` → `.symmetricSigning`; `algNoneRejected` → `.failed`.
  - `unknownKidReported` → `.unknownKey(kid: "zz")`.
  - `optionalClaimsMayBeMissing` → only `sub` → identity with nil name/email/username.
- [ ] **Step 2:** `swift test --filter OIDCTokenValidator` → FAIL.
- [ ] **Step 3:** Implement. Read `alg`/`kid` from the Base64URL header yourself before verifying; reject algorithms
  outside the set; then `keys.verify` with a payload type whose `verify(using:)` checks `exp`/`iat` with 60 s leeway;
  then `iss` exact, `aud` contains client ID, `azp` rule, `nonce`.
- [ ] **Step 4:** `swift test --filter OIDCTokenValidator` → PASS; `swift build` clean.
- [ ] **Step 5:** Commit `feat(oidc): ID token validation with jwt-kit`.

### Task 4: Discovery and token exchange (`LiveOIDCProvider`)

**Files:**
- Create: `Sources/App/Auth/OIDC/OIDCProvider.swift` (protocol, `OIDCDiscovery`, `OIDCTransport`, `VaporOIDCTransport`)
- Create: `Sources/App/Auth/OIDC/LiveOIDCProvider.swift`
- Create: `Tests/AppTests/Support/FakeOIDCTransport.swift`, Test: `Tests/AppTests/LiveOIDCProviderTests.swift`

**Interfaces:**
- Consumes: `OIDCConfig`, `OIDCTokenValidator`, `OIDCError`.
- Produces: `protocol OIDCProvider: Sendable { func authorizationURL(state: String, nonce: String, codeChallenge: String) async throws -> URL;
  func exchange(code: String, codeVerifier: String, nonce: String) async throws -> OIDCIdentity; func discoveredIssuer() async throws -> String }`.
- Produces: `protocol OIDCTransport: Sendable { func get(_ url: URL) async throws -> (status: UInt, body: Data);
  func postForm(_ url: URL, fields: [String: String], basicAuth: (user: String, password: String)?) async throws -> (status: UInt, body: Data) }`,
  `struct VaporOIDCTransport: OIDCTransport { let client: any Client }` (network errors → `OIDCError.unreachable`).
- Produces: `actor LiveOIDCProvider: OIDCProvider { init(config: OIDCConfig, transport: any OIDCTransport, logger: Logger, now: @escaping @Sendable () -> Date = { .now }) }`.

- [ ] **Step 1: Failing tests** (`@Suite("LiveOIDCProvider")`, `FakeOIDCTransport` maps URL → (status, body) and records requests):
  - `authorizationURLHasAllParameters`: query has `response_type=code`, `scope=openid profile email`, `client_id`,
    `redirect_uri`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`, no `prompt`.
  - `discoveryWithAndWithoutTrailingSlash`: issuer config `https://id.example.test/app/` and `…/app` both GET
    `…/app/.well-known/openid-configuration`.
  - `discoveryIssuerMismatchFails` → `.misconfigured`.
  - `discoveryCachedFor24Hours`: two calls → one GET; with `now` + 24 h + 1 s → second GET.
  - `usesBasicAuthWhenOffered` (methods absent or contain `client_secret_basic`), `usesPostWhenOnlyPostOffered`
    (`client_id`/`client_secret` in the form); Basic credentials form-urlencoded (secret `a b+c` → `a+b%2Bc`).
  - `exchangeReturnsValidatedIdentity` (ES256 JWKS from `OIDCTestKeys`).
  - `unknownKidReloadsOnceThenFails`: token with new kid → one extra JWKS GET → success if new JWKS has it; a second
    unknown kid within 60 s → no GET, `.failed`.
  - `discoveryDroppedAfterTokenEndpoint404`: token endpoint 404 → `.failed`; next `authorizationURL` GETs discovery again.
  - `symmetricOnlyProviderRejected`: `id_token_signing_alg_values_supported: ["HS256"]` → `.symmetricSigning`.
  - `unreachableProviderMapsToUnreachable`, `tokenErrorDoesNotLeakCode` (`String(describing: error)` lacks code and body).
- [ ] **Step 2:** `swift test --filter LiveOIDCProvider` → FAIL.
- [ ] **Step 3:** Implement. Discovery URL = issuer without trailing slash + `/.well-known/openid-configuration`.
  Token request fields: `grant_type=authorization_code`, `code`, `redirect_uri`, `code_verifier`. Response: only
  `id_token` is read. Discovery is dropped on 404 or `.unreachable` from token/JWKS endpoint.
- [ ] **Step 4:** `swift test --filter LiveOIDCProvider` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): discovery, JWKS and token exchange`.

### Task 5: Wiring, flow cookie, start and callback for known identities

**Files:**
- Create: `Sources/App/Auth/OIDC/OIDCFlowCookie.swift`, `Sources/App/Auth/OIDC/OIDCController.swift`
- Modify: `Sources/App/configure.swift` (parameter `oidcProvider:`, storage, origins), `Sources/App/Config/Application+Services.swift`,
  `Sources/App/routes.swift`, `Sources/App/Web/Pages/LoginPage.swift`, `Sources/App/Auth/AuthController.swift`
- Create: `Tests/AppTests/Support/FakeOIDCProvider.swift`, `Tests/AppTests/Support/OIDCFlow.swift`
- Modify: `Tests/AppTests/Support/TestApp.swift` (`withTestApp(…, oidc: FakeOIDCProvider = FakeOIDCProvider(), …)`)
- Test: `Tests/AppTests/OIDCFlowCookieTests.swift`, `Tests/AppTests/OIDCLoginTests.swift`

**Interfaces:**
- Produces: `enum OIDCIntent: String, Codable { case login, link, reauth, linkToken, invite }`;
  `struct OIDCFlowCookie: Codable, Sendable { var state, nonce, verifier: String; var startedAt: Date; var intent: OIDCIntent;
  var returnTo, linkToken, inviteToken: String?; var pending: OIDCIdentity?; var pendingAt: Date?;
  static let name = "watchswifty_oidc"; func seal(_ cipher: TokenCipher) throws -> String;
  static func open(_ value: String?, cipher: TokenCipher, now: Date) -> OIDCFlowCookie?;
  func cookie(_ cipher: TokenCipher, secure: Bool) throws -> HTTPCookies.Value; static var expired: HTTPCookies.Value }`
  (`open` rejects when the newer of `startedAt`/`pendingAt` is older than 600 s).
- Produces: `app.oidcProvider: (any OIDCProvider)?`, `app.oidcIdentityLock: AsyncMutex`;
  `configure(_:config:tmdbProvider:releaseFetcher:mailSender:oidcProvider: (any OIDCProvider)? = nil)` — with
  `config.oidc` and no fake → `LiveOIDCProvider(config:transport: VaporOIDCTransport(client: app.client), logger:)`;
  `config.oidc.canonicalOrigin` appended to `OriginCheckMiddleware` origins.
- Produces: `struct OIDCController { func register(on: any RoutesBuilder) }` routes `GET /auth/oidc/start`,
  `GET /auth/oidc/callback` (registered only with `config.oidc`); `func isCanonical(_ req: Request, _ oidc: OIDCConfig) -> Bool`
  (wraps `OriginCheckMiddleware.requestMatches`).
- Produces (tests): `FakeOIDCProvider` (`identity: OIDCIdentity?`, `error: OIDCError?`, records `lastState`, `lastNonce`,
  `exchanges`; `exchange` throws `.failed` if `nonce != lastNonce`); `func oidcFlow(_ app: Application, _ fake: FakeOIDCProvider,
  start: String = "/auth/oidc/start", headers: HTTPHeaders = .sameOrigin) async throws -> OIDCFlowResult` with
  `status`, `location`, `body`, `headers` (session + oidc cookie for the next request);
  `func oidcIdentity(_ sub: String = "sub-1", username: String? = "anna", email: String? = "anna@example.org") -> OIDCIdentity`
  (issuer `https://id.example.test`).

- [ ] **Step 1: Failing tests.** `OIDCFlowCookieTests`: `roundTrip`, `tamperedCookieRejected`, `oldCookieRejected`
  (startedAt − 601 s), `otherKeyRejected`. `OIDCLoginTests` (config `.testingOIDC`):
  - `loginPageShowsSSOButton` (body contains „Mit SSO anmelden“ and `/auth/oidc/start`; with `returnTo` kept).
  - `startRedirectsToProvider`: 303 to the fake URL; `Set-Cookie` has `watchswifty_oidc` with `Path=/auth/oidc`, `HttpOnly`.
  - `anonymousStartCreatesNoSession`: `SessionRecord.query(on: app.db).count()` unchanged; no `watchswifty_session` cookie.
  - `startOnOtherHostRedirectsToCanonical`: `Host: other.lan:8080` → 303 to `http://localhost:8080/auth/oidc/start?returnTo=…`.
  - `canonicalHostWithoutForwardedProtoDoesNotRedirect` (Review Focus 1): redirect URL `https://localhost:8080/…`
    config, request `Host: localhost:8080` → goes to provider, not to itself.
  - `startWithUnreachableProviderShowsMessage`: fake error `.unreachable` → 503 with „SSO ist gerade nicht erreichbar.“
  - `callbackWithoutCookieFails` (Review Focus 2): 400, „Anmeldung abgelaufen – bitte erneut versuchen.“; same with `?error=access_denied` and no cookie.
  - `cookieIsSingleUse`, `staleCookieFails`, `stateMismatchFails`.
  - `accessDeniedShowsMessage` → „SSO hat die Anmeldung abgelehnt.“; other `error` → „Anmeldung über SSO fehlgeschlagen.“
  - `knownIdentitySignsIn`: user with issuer/subject → 303 to `/`, session cookie works on `/account`.
  - `knownIdentityKeepsSafeReturnTo` (`/api/auth/authorize?x=1`) and `unsafeReturnToDropped` (`https://evil`).
  - `sameSubjectOtherIssuerIsUnknown`: stored issuer `https://old.example` → not signed in (303 to `/auth/oidc/new-account`).
- [ ] **Step 2:** `swift test --filter OIDCFlowCookie` and `--filter OIDCLogin` → FAIL.
- [ ] **Step 3:** Implement start/callback per spec „Ablauf“ for intents `login` (known identity only; unknown →
  park identity in the cookie and redirect to `/auth/oidc/new-account`, handled in Task 6). Error pages render
  `LoginPage(error:)` (OIDC button visible). `AuthController.loginPage` passes `ssoName`/`passwordLogin` to `LoginPage`.
- [ ] **Step 4:** both filters PASS; `swift test --filter Auth` PASS.
- [ ] **Step 5:** Commit `feat(oidc): sign in with a linked provider account`.

### Task 6: New accounts (`OIDCLoginService`, confirmation page)

**Files:**
- Create: `Sources/App/Auth/OIDC/OIDCLoginService.swift`, `Sources/App/Web/Pages/NewAccountPage.swift`
- Modify: `Sources/App/Auth/OIDC/OIDCController.swift` (`GET`/`POST /auth/oidc/new-account`, email sync on login)
- Test: `Tests/AppTests/OIDCLoginTests.swift`

**Interfaces:**
- Consumes: `OIDCFlowCookie`, `app.oidcIdentityLock`, `User` helpers.
- Produces: `struct OIDCLoginService { let db: any Database; let cipher: TokenCipher; let oidc: OIDCConfig; let passwordLogin: Bool; let lock: AsyncMutex;
  func account(for identity: OIDCIdentity) async throws -> User?;
  func createAccount(_ identity: OIDCIdentity, username: String) async throws -> User;
  func link(_ user: User, to identity: OIDCIdentity) async throws;
  func syncEmail(_ user: User, from identity: OIDCIdentity) async throws;
  static func suggestUsername(_ identity: OIDCIdentity) -> String?; func readiness() async throws -> OIDCReadiness }`,
  `struct OIDCReadiness: Equatable { let linked, total: Int; let adminLinked: Bool }`, `extension Request { var oidcLogin: OIDCLoginService }`.
  `createAccount` returns the existing account if the identity got linked meanwhile (double submit);
  `link` throws `APIError.validation(„Dieses {name}-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.“)`
  for a foreign identity and for a unique-index violation; both run under `lock.withLock`.

- [ ] **Step 1: Failing tests** in `OIDCLoginTests`:
  - `unknownIdentityAlwaysConfirms`: free valid `preferred_username` → 303 to `/auth/oidc/new-account`, no user created; page shows „Mit SSO ist noch kein WatchSwifty-Konto verknüpft.“ and the passwort-login hint text.
  - `suggestionFromPreferredUsername` (`Anna` → `anna`), `suggestionFromEmail` (no username, `p.meier@x.de` → `p.meier`),
    `invalidSuggestionLeavesFieldEmpty` (Kanidm `ab@idm.example` → `ab` too short → empty),
    `nonASCIISuggestion` (Review Focus 5: `jörg` → `jrg`; name „Jörg Müller“ only → `jrgmller`; page 200),
    `takenSuggestionLeavesFieldEmpty` (+ text that the name is taken).
  - `confirmCreatesAccountWithoutPassword`: POST `username=anna` → user without password, linked, email sealed and readable as `anna@example.org`, redirect `/account?welcome=1`.
  - `confirmTakenNameFails` → 422 with `AccountValidation.duplicateMessage`; `confirmInvalidNameFails` → `usernameMessage`.
  - `doubleSubmitSignsInOnce` (Review Focus 3): two POSTs with the same cookie → one user, second 303 signed in.
  - `cancelClearsCookie`, `pendingIdentityExpires` (cookie with `pendingAt` − 601 s → „Anmeldung abgelaufen …“).
  - `firstAccountBecomesAdminOnlyOnEmptyDatabase` (config without ADMIN_* bootstrap: `adminUsername = nil`), `concurrentFirstLoginsCreateOneAdmin` (two `createAccount` in a task group → exactly one admin).
  - `accountWithoutPasswordEmailFollowsProvider`: second login with `ANNA@Example.org ` → stored `anna@example.org` (Review Focus 4); login without `email` keeps it.
  - `accountWithPasswordEmailNeverOverwritten`: linked user with password, also with `passwordLogin = false`.
  - `passwordLoginForAccountWithoutPasswordStillFails`: POST `/login` for the SSO account → „Benutzername oder Passwort falsch.“
- [ ] **Step 2:** `swift test --filter OIDCLogin` → new tests FAIL.
- [ ] **Step 3:** Implement per spec „Neues Konto anlegen“ and „E-Mail-Adresse vom Provider“. Suggestion: candidate →
  `User.normalize` → keep only `a–z0–9._-` → prefix 32 → valid by `AccountValidation.usernameError` else next
  candidate. First user → admin only if `User.query.count() == 0` inside the lock.
- [ ] **Step 4:** `swift test --filter OIDCLogin` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): confirm new accounts on first sign-in`.

### Task 7: Linking from the account page, provider e-mail rules

**Files:**
- Modify: `Sources/App/Account/AccountController.swift` (`POST /account/oidc/link`), `Sources/App/Account/AccountService.swift`
  (`setEmail` rule), `Sources/App/Web/Pages/AccountPage.swift` (SSO section, read-only address, password section rule),
  `Sources/App/Auth/OIDC/OIDCController.swift` (intent `link`), `Sources/App/API/APIError.swift`
- Test: `Tests/AppTests/OIDCLinkTests.swift`

**Interfaces:**
- Produces: `APIError.emailFromProvider(name: String) -> APIError` (409, code `emailFromProvider`,
  „Die Adresse kommt von {name} – bitte dort ändern.“).
- `AccountService` gains `oidc: OIDCConfig?`, `passwordLogin: Bool` (wired in `req.account`).
- Session key `oidc.intent` (`"link"`/`"reauth"`), read and removed by `/auth/oidc/start` only for a signed-in user.

- [ ] **Step 1: Failing tests** (`@Suite("OIDCLink")`):
  - `linkFromAccountPage`: logged-in password user → POST `/account/oidc/link` (same origin) → start → callback → account page notice „Mit SSO verknüpft.“, user linked.
  - `linkIntentNotFromQuery`: GET `/auth/oidc/start?intent=link` while logged in, callback with a new identity → no link (goes to new-account).
  - `linkReplacesOldIssuer`, `oldIssuerShowsLinkButton` (account page has „Mit SSO verknüpfen“).
  - `linkToIdentityOfOtherAccountFails` (message from spec, nothing changed); `concurrentLinkSameIdentityOneWins` (two `link` calls → one throws the validation error, no 500).
  - `linkOnOtherHostRedirectsToCanonicalAccount`: POST with `Host`/`Origin` `other.lan:8080` → 303 to `http://localhost:8080/account` with the spec notice.
  - `setEmailForAccountWithoutPasswordConflicts`: web POST `/account/email` → 409 with the message; account page shows the address read-only with „kommt von SSO – dort ändern“.
  - `passwordSectionOnlyWithPassword`: SSO account page lacks „Passwort ändern“.
- [ ] **Step 2:** `swift test --filter OIDCLink` → FAIL.
- [ ] **Step 3:** Implement per spec „Bestehende Konten verknüpfen“ (account page part).
- [ ] **Step 4:** `swift test --filter OIDCLink` and `--filter Account` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): link existing accounts`.

### Task 8: Link tokens (admin button, `link-oidc`)

**Files:**
- Modify: `Sources/App/Auth/OIDC/OIDCController.swift` (`?link=` → intent `linkToken`), `Sources/App/Admin/UserAdminService.swift`
  (`createSSOLink`), `Sources/App/Admin/AdminUsersController.swift` (`POST /admin/users/:userID/sso-link`),
  `Sources/App/Web/Pages/AdminUsersPage.swift` (button, one-time link display), `Sources/App/Mail/MailTexts.swift` (`ssoLink`)
- Create: `Sources/App/Auth/OIDC/OIDCCommands.swift` (`LinkOIDCCommand`), register in `configure.swift` as `link-oidc`
- Test: `Tests/AppTests/OIDCLinkTests.swift`

**Interfaces:**
- Produces: `struct SSOLinkResult: Equatable { let mailed: Bool; let emailHint: String?; let url: String?; let mailError: String? }`;
  `UserAdminService.createSSOLink(id: UUID, inviter: User) async throws -> SSOLinkResult` (self → `APIError.selfAction`;
  OIDC missing → `APIError.notFound`; already linked → `APIError.validation`); link URL =
  `oidc.canonicalOrigin + "/auth/oidc/start?link=" + token`, lifetime `adminLifetime`.
- `UserAdminService` gains `oidc: OIDCConfig?`, `passwordLogin: Bool` (wired in both `userAdmin` accessors).
- Produces: `MailTexts.ssoLink(to: String, username: String, inviter: String, ssoName: String, link: String, expires: Date) -> OutgoingMail`
  (subject „WatchSwifty: Konto mit {ssoName} verknüpfen“; body in the invite style: who sent it, the username, the
  link with expiry date, „Danach meldest du dich immer über {ssoName} an.“).
- Produces: `struct LinkOIDCCommand: AsyncCommand` (argument `benutzer`): clears issuer/subject, issues with
  `commandLifetime`, prints „Verknüpfungslink für {user} (1 Stunde gültig): {url}“.

- [ ] **Step 1: Failing tests** in `OIDCLinkTests`:
  - `linkTokenLinksAndSignsIn` (callback → linked, signed in as target, token consumed), `linkTokenIsSingleUse`, `expiredLinkTokenFails` (spec message).
  - `linkTokenNotUsableAtResetPassword`: GET `/reset-password?token=<link token>` → „Der Link ist ungültig …“.
  - `adminSSOLinkMailsWhenPossible` (mail configured + address → one mail to it, notice with mask), `adminSSOLinkShownWithoutMail` (page contains the URL once), `adminSSOLinkShownWhenMailFails` (FakeMailSender failure → URL + reason), `adminSSOLinkNotForSelf` (422), `adminSSOLinkHiddenForLinked`.
  - `linkCommandUnlinksAndPrintsURL` (run via `app.asyncCommands` with a test console; output contains `/auth/oidc/start?link=`; user unlinked), `linkCommandWithoutOIDCFails`, `linkCommandUnknownUserFails`.
- [ ] **Step 2:** `swift test --filter OIDCLink` → new tests FAIL.
- [ ] **Step 3:** Implement per spec „Bestehende Konten verknüpfen“ (admin part) and „Notausgang“. Look at
  `ResetPasswordCommandTests` for running a command in tests.
- [ ] **Step 4:** `swift test --filter OIDCLink`, `--filter Admin`, `--filter ResetPasswordCommand` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): link tokens from the admin page and link-oidc`.

### Task 9: Invitations via SSO

**Files:**
- Modify: `Sources/App/Auth/OIDC/OIDCController.swift` (`?invite=` → intent `invite`), `Sources/App/Auth/PasswordResetController.swift`,
  `Sources/App/Web/Pages/ResetPasswordPage.swift` (SSO button; password form only with password login), `Sources/App/Mail/MailTexts.swift` (`invite` gains `ssoName: String?, passwordLogin: Bool`)
- Test: `Tests/AppTests/OIDCInviteTests.swift`

**Interfaces:**
- Consumes: `PasswordTokenService.check`, `OIDCLoginService.link`.
- `ResetPasswordPage` gains `ssoName: String?` and `passwordLogin: Bool`.

- [ ] **Step 1: Failing tests** (`@Suite("OIDCInvite")`):
  - `invitePageOffersSSO`: invite token page has „Mit SSO verknüpfen“ → `/auth/oidc/start?invite=<token>` and the password form.
  - `inviteViaSSOLinksAndWelcomes`: callback → invitee linked, `PasswordToken` rows of the user deleted, 303 `/account?welcome=1`.
  - `expiredInviteViaSSOFails` → „Die Einladung ist abgelaufen – bitte wende dich an deinen Admin.“
  - `inviteMailMentionsSSO`: with OIDC the mail body names both ways; with `passwordLogin = false` only „über SSO anmelden“.
  - `resetTokenNotAcceptedAsInvite`: `?invite=<reset token>` → invalid message.
- [ ] **Step 2:** `swift test --filter OIDCInvite` → FAIL.
- [ ] **Step 3:** Implement per spec „Einladungen“.
- [ ] **Step 4:** `swift test --filter OIDCInvite`, `--filter Invite`, `--filter PasswordReset` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): accept invitations through the provider`.

### Task 10: Admin page and startup readiness

**Files:**
- Modify: `Sources/App/Admin/UserAdminService.swift` (`row(for:)` invite rule, `resendInvite` guard),
  `Sources/App/Web/Pages/AdminUsersPage.swift` (badge, status box), `Sources/App/Admin/AdminUsersController.swift`,
  `Sources/App/Auth/AdminBootstrap.swift`
- Test: `Tests/AppTests/OIDCAdminTests.swift`

**Interfaces:**
- `AdminUserRow` gains `ssoLinked: Bool`.
- `bootstrapAdmin(config:db:logger:hasher:)` unchanged signature; uses `OIDCLoginService.readiness()`-equivalent query.

- [ ] **Step 1: Failing tests** (`@Suite("OIDCAdmin")`):
  - `linkedAccountWithoutPasswordIsNoInvitation`: page lacks „Einladung abgelaufen“/„Einladung erneut senden“ for it, shows badge „SSO“.
  - `resendInviteForLinkedAccountFails` → 422 „Das Konto ist mit SSO verknüpft – keine Einladung nötig.“
  - `statusBoxCountsCurrentIssuerOnly`: 3 users, 1 linked current, 1 old issuer → „1 von 3 Konten mit SSO verknüpft“, „Admin verknüpft: nein“, hint sentence while password login is on.
  - `oidcDisabledTreatsLinkedAsInvitation`: config without OIDC → linked user without password shows „Einladung abgelaufen“ and resend works (mail configured).
  - `startupWarnsWithoutLinkedAdmin`: `readiness()` with `passwordLogin = false` → `adminLinked == false`; bootstrap logs the spec warning (capture via a test `LogHandler` or assert the returned readiness used by bootstrap).
  - `adminEnvIgnoredWithoutPasswordLogin`: `.testingOIDC` + `passwordLogin = false` → no admin created at startup.
- [ ] **Step 2:** `swift test --filter OIDCAdmin` → FAIL.
- [ ] **Step 3:** Implement per spec „Konten ohne Passwort“, „Passwort-Login abgeschaltet“ (startup lines).
- [ ] **Step 4:** `swift test --filter OIDCAdmin`, `--filter Admin` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): link status on the users page`.

### Task 11: Password login switched off (web)

**Files:**
- Modify: `Sources/App/Auth/AuthController.swift`, `Sources/App/Auth/PasswordResetController.swift`,
  `Sources/App/Account/AccountController.swift`, `Sources/App/Account/AccountService.swift`,
  `Sources/App/Admin/AdminUsersController.swift`, `Sources/App/Admin/UserAdminService.swift`,
  `Sources/App/Web/Pages/LoginPage.swift`, `Sources/App/Web/Pages/AdminUsersPage.swift`, `Sources/App/API/APIError.swift`
- Test: `Tests/AppTests/PasswordLoginDisabledTests.swift`

**Interfaces:**
- Produces: `APIError.passwordLoginDisabled` (409, code `passwordLoginDisabled`, „Der Passwort-Login ist abgeschaltet.“).
- Services throw it from `changePassword`, `UserAdminService.resetPassword`, `UserAdminService.create` (when a password
  is given; web message „Der Passwort-Login ist abgeschaltet – nur Einladungen.“). Web routes that vanish check
  `config.passwordLogin` first and throw `Abort(.notFound)`.

- [ ] **Step 1: Failing tests** (`@Suite("PasswordLoginDisabled")`, config `.testingOIDC` with `passwordLogin = false`):
  - `loginPageShowsOnlyOIDC` (no password field, no „Passwort vergessen?“), `passwordLoginReturns404`.
  - `forgotReturns404` (GET/POST), `resetLinkInvalidAndPostReturns404`.
  - `accountPasswordReturns404`.
  - `adminCreateOnlyAsInvitation`: form lacks „Startpasswort“; POST with password → 409 with the message; without password + email (mail configured) → invitation sent.
  - `adminSetPasswordReturns404`; resend invite still works.
- [ ] **Step 2:** `swift test --filter PasswordLoginDisabled` → FAIL.
- [ ] **Step 3:** Implement per spec table „Passwort-Login abgeschaltet“ (web column).
- [ ] **Step 4:** `swift test --filter PasswordLoginDisabled` and the whole suite `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): switch off the password login`.

### Task 12: App API

**Files:**
- Modify: `Sources/WatchSwiftyAPI/openapi.yaml` (first), `Sources/App/API/APIHandler+Auth.swift`, `+Account.swift`, `+Admin.swift`
- Test: `Tests/AppTests/APIOIDCTests.swift`

**Interfaces:**
- YAML: `Me` required `ssoLinked: boolean`, `passwordLogin: boolean`, corrected `hasPassword` description;
  `UserSummary` required `ssoLinked: boolean`; `409` responses (`passwordLoginDisabled`) on `changePassword`,
  `createUser`, `resetUserPassword`; `409` (`emailFromProvider`) description on `setEmail`; new operation
  `createSSOLink` `POST /v1/admin/users/{id}/sso-link` (tag Admin, bearer) → `200 SSOLinkResult { mailed: boolean
  (required), emailHint, url, mailError: string }`, `404`, `422`.
- Handler: `createSSOLink` calls `userAdmin.createSSOLink`.

- [ ] **Step 1: Failing tests** (`@Suite("APIOIDC")`):
  - `meReportsSSOFlags` (linked user without password → `ssoLinked == true`, `hasPassword == false`; `passwordLogin` mirrors config).
  - `userSummaryHasSSOLinked` and `invitePending == false` for linked accounts.
  - `changePasswordDisabled` → 409 `passwordLoginDisabled`; `createUserWithPasswordDisabled` → 409; `resetUserPasswordDisabled` → 409.
  - `setEmailFromProvider` → 409 `emailFromProvider`.
  - `createSSOLinkMailsOrReturnsURL`, `createSSOLinkSelf` → 422 `selfAction`, `createSSOLinkWithoutOIDC` → 404.
  - `specMatchesSource` (existing `APIDocsTests`) stays green.
- [ ] **Step 2:** `swift test --filter APIOIDC` → FAIL (after YAML edit: build errors until handlers exist — implement `createSSOLink` stub first).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter API` → PASS.
- [ ] **Step 5:** Commit `feat(api): SSO flags, link tokens and disabled password login`.

### Task 13: App connect via the provider (reauth)

**Files:**
- Modify: `Sources/App/API/APIAuthorizeController.swift`, `Sources/App/Auth/OIDC/OIDCController.swift` (intent `reauth`)
- Test: `Tests/AppTests/APIAuthorizeOIDCTests.swift`

**Interfaces:**
- Session key `oidc.verifiedAt` (seconds since 1970 as string); helper `func isFreshlyVerified(_ req: Request, now: Date) -> Bool` (≤ 300 s).

- [ ] **Step 1: Failing tests** (`@Suite("APIAuthorizeOIDC")`, valid authorize query as in `APIAuthorizeTests`):
  - `ssoAccountMustReauthenticate`: signed-in SSO account → 303 to `/auth/oidc/start?returnTo=%2Fapi%2Fauth%2Fauthorize%3F…`.
  - `reauthWithSameIdentityShowsConnect`: after the flow → GET authorize shows „Verbinden“.
  - `reauthWithOtherIdentityFails` → „Bei SSO ist ein anderes Konto angemeldet.“, no code issued (`app.authCodes` empty).
  - `decideWithoutFreshReauthIssuesNoCode`: direct POST `decision=connect` → 303 to start, no `code=` in location.
  - `reauthExpiresAfterFiveMinutes` (verifiedAt − 301 s → redirect again).
  - `passwordAccountNeedsNoReauth`, `passwordAccountNotRedirectedToCanonical` (Host `other.lan:8080`, signed in with password → page shown).
  - `anonymousOnOtherHostRedirectsToCanonical`.
- [ ] **Step 2:** `swift test --filter APIAuthorizeOIDC` → FAIL.
- [ ] **Step 3:** Implement per spec „App verbinden“.
- [ ] **Step 4:** `swift test --filter APIAuthorize` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): re-check the provider before connecting an app`.

### Task 14: Issuer move command

**Files:**
- Modify: `Sources/App/Auth/OIDC/OIDCCommands.swift` (`MoveOIDCIssuerCommand`), `Sources/App/configure.swift` (`oidc-move-issuer`)
- Test: `Tests/AppTests/OIDCMigrationTests.swift`

**Interfaces:**
- Produces: `struct MoveOIDCIssuerCommand: AsyncCommand` (arguments `alt`, `neu`); core in
  `OIDCLoginService.moveIssuer(from: String, to: String) async throws -> Int` (transaction; trailing-slash-insensitive
  match on `from`; conflict → `APIError.validation`, nothing changed).

- [ ] **Step 1: Failing tests:** `moveIssuerRewritesAll` (2 users → returns 2, both on new issuer), `moveIssuerConflictChangesNothing`, `moveIssuerUnknownOldIsNoop` (0), `moveIssuerCommandWithoutOIDCFails`, `reenablingOIDCRestoresLinks` (config off → on, same issuer → linked again).
- [ ] **Step 2:** `swift test --filter OIDCMigration` → FAIL.
- [ ] **Step 3:** Implement; the command warns (does not fail) when `discoveredIssuer()` differs from `neu` or is unreachable.
- [ ] **Step 4:** `swift test --filter OIDCMigration` → PASS.
- [ ] **Step 5:** Commit `feat(oidc): oidc-move-issuer command`.

### Task 15: Documentation and final check

**Files:**
- Modify: `README.md` (section „Anmeldung über OIDC (SSO)“, configuration table, commands), `.env.example`,
  `docker-compose.yml` (commented OIDC variables), `CHANGELOG.md` (`## [Unveröffentlicht]` → `### Neu`),
  `docs/superpowers/specs/2026-11-09-mail-design.md` (addendum: invitations via SSO, „Verknüpfungslink“ mail),
  `CLAUDE.md` (OIDC folder, `oidc` test helpers, commands)

- [ ] **Step 1:** Write the README section from spec „Doku“ and „Migration“ (switch-over steps, provider change,
  issuer move, way back, Authentik and Pocket ID examples, `link-oidc`, `oidc-move-issuer`, `reset-password`).
- [ ] **Step 2:** `swift test` → all suites PASS (expect 554 + new tests, 0 failures); `swift build -c release` succeeds.
- [ ] **Step 3:** Preview check: start `watchswifty` from `.claude/launch.json`; login page renders unchanged without OIDC.
- [ ] **Step 4:** Commit `docs(oidc): README, compose, changelog`.
- [ ] **Step 5:** Whole-branch review (fresh reviewer, most capable model) against the spec; fix findings with their own commits.

---

## Addendum (2026-11-10): settings in the UI

Spec: section „Einstellungen (System → Anmeldung (SSO))“ and decision 13. Replaces `OIDC_*` environment variables;
`PASSWORD_LOGIN=true` is the only remaining variable (emergency switch).

### Task 16: Settings storage and runtime store

**Files:** Create `Sources/App/Auth/OIDC/OIDCSettings.swift` (`OIDCSettings`, `OIDCSettingsState`, `OIDCSettingsInput`,
`OIDCSettingsService`, `AddOIDCConfig` migration on `app_settings.oidc_config`), `Sources/App/Auth/OIDC/LoginSettings.swift`
(`LoginSettings`, `LoginSettingsStore`, `OIDCProviderStore`); modify `AppConfig` (drop env parsing of `OIDC_*`,
`passwordLoginForced` from `PASSWORD_LOGIN=true`), `configure.swift` (seed from `AppConfig.oidc` for tests, load store,
provider store), every `appConfig.oidc`/`appConfig.passwordLogin` read → `application.loginSettings.current`,
`OriginCheckMiddleware` (dynamic canonical origin), `OIDCController.register` (always registered, 404 when off).
Test: `OIDCSettingsTests` (validation messages, secret keep/re-entry rule, sealed storage, unreadable → OIDC off,
reload on save, `PASSWORD_LOGIN=true` forces on, env `OIDC_*` ignored), existing suites stay green.

### Task 17: `check()` and the System page

**Files:** `OIDCProvider.check()` in protocol, `LiveOIDCProvider`, `FakeOIDCProvider`; `SystemController`
(`POST /admin/system/oidc`, `/oidc/test`, `/oidc/delete`, `/password-login`), `SystemPage` section. Test:
`SystemOIDCTests` (save → active immediately and login button appears, save with failing check still saves and
warns, test button messages, delete blocked while password login is off, password login off blocked without OIDC
or without own link, forced switch shown and locked, non-admin 403).

### Task 18: App API for the settings

**Files:** `openapi.yaml` (`/v1/admin/oidc`, `/v1/admin/oidc/test`, `/v1/admin/oidc/password-login`, schemas
`OIDCSettings`, `OIDCSettingsUpdate`, `OIDCCheck`, `PasswordLoginUpdate`), `APIHandler+Admin`. Test: `APIOIDCSettingsTests`
(secret never in responses, same validation/guards, test endpoint).

### Task 19: Docs

README (setup under System, emergency `PASSWORD_LOGIN=true`), `.env.example`/compose (remove `OIDC_*`), CHANGELOG,
CLAUDE.md, spec cross-checks.
