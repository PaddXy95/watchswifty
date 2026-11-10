import Fluent
import Vapor

/// Creates the first admin from ADMIN_USERNAME / ADMIN_PASSWORD while no user exists (not without password login);
/// logs where the switch-over to OIDC stands.
func bootstrapAdmin(config: AppConfig, db: any Database, logger: Logger, hasher: any PasswordHasher) async throws {
    if let oidc = config.oidc {
        let readiness = try await OIDCLoginService.readiness(db: db, oidc: oidc)
        if !config.passwordLogin, config.adminPassword != nil, readiness.total == 0 {
            logger.notice("ADMIN_USERNAME/ADMIN_PASSWORD werden ignoriert, weil PASSWORD_LOGIN=false gesetzt ist.")
        }
        let creates = config.passwordLogin && readiness.total == 0 && config.adminUsername != nil && config.adminPassword != nil
        if !creates {
            for warning in startupWarnings(config: config, readiness: readiness) { logger.warning("\(warning)") }
        }
        guard config.passwordLogin else { return }
    }
    guard try await User.query(on: db).count() == 0 else { return }
    guard let username = config.adminUsername, let password = config.adminPassword else {
        if config.oidc == nil { logger.warning("Kein Benutzer vorhanden – ADMIN_USERNAME und ADMIN_PASSWORD setzen.") }
        return
    }
    guard password.count >= 8 else {
        logger.warning("ADMIN_PASSWORD muss mindestens 8 Zeichen haben – kein Admin angelegt.")
        return
    }
    let admin = User(username: User.normalize(username), passwordHash: try hasher.hash(password), isAdmin: true)
    try await admin.save(on: db)
    logger.info("Admin \(admin.username) angelegt.")
}

/// Startup hints while OIDC is configured (spec „Passwort-Login abgeschaltet“).
func startupWarnings(config: AppConfig, readiness: OIDCReadiness) -> [String] {
    guard let oidc = config.oidc else { return [] }
    if readiness.total == 0 { return ["Kein Benutzer vorhanden – der erste Login über \(oidc.displayName) wird Admin."] }
    guard !config.passwordLogin else { return [] }
    var warnings: [String] = []
    if !readiness.adminLinked {
        warnings.append("Kein Admin ist mit \(oidc.displayName) verknüpft – mit `link-oidc <admin>` einen Verknüpfungslink erzeugen.")
    }
    let unlinked = readiness.total - readiness.linked
    if unlinked > 0 {
        warnings.append("\(unlinked) Konten sind noch nicht mit \(oidc.displayName) verknüpft (Verknüpfungslink auf der Benutzer-Seite).")
    }
    return warnings
}
