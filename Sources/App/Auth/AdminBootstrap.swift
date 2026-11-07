import Fluent
import Vapor

/// Creates the first admin from ADMIN_USERNAME / ADMIN_PASSWORD while no user exists.
func bootstrapAdmin(config: AppConfig, db: any Database, logger: Logger, hasher: any PasswordHasher) async throws {
    guard try await User.query(on: db).count() == 0 else { return }
    guard let username = config.adminUsername, let password = config.adminPassword else {
        logger.warning("Kein Benutzer vorhanden – ADMIN_USERNAME und ADMIN_PASSWORD setzen.")
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
