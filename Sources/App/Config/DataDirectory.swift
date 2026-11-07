import Foundation

/// Fails with a German hint instead of an SQLite crash when the database folder is not writable
/// (typically a bind mount owned by another user).
func checkDataDirectory(databasePath: String) throws {
    guard databasePath != ":memory:" else { return }
    let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
    guard !FileManager.default.isWritableFile(atPath: directory) else { return }
    throw ConfigError.invalid(
        "Kein Schreibzugriff auf \(directory) (App läuft als UID \(getuid())). Den Datenordner auf dem Server dem "
            + "App-Benutzer geben, z. B. `sudo chown -R \(getuid()):\(getgid()) <ordner>`, oder ein Docker-Volume verwenden."
    )
}
