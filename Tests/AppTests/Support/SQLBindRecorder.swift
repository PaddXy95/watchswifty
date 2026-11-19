@testable import App
import Fluent
import Foundation
import Logging
import Vapor

/// Records the number of bound values of every SQL statement sent through `database(_:)`, so a test can check
/// that no statement grows with stored data (SQLite rejects more than 250,000 binds; security audit F04/F15).
final class SQLBindRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [(sql: String, binds: Int)] = []

    /// The statement with the most binds so far.
    var largest: (sql: String, binds: Int)? {
        lock.withLock { statements.max { $0.binds < $1.binds } }
    }

    /// Every recorded statement, in order.
    var sqls: [String] {
        lock.withLock { statements.map(\.sql) }
    }

    /// Whether a recorded statement contains `fragment` (a check that the statement under test was seen at all).
    func saw(_ fragment: String) -> Bool {
        lock.withLock { statements.contains { $0.sql.contains(fragment) } }
    }

    /// The app's database, logging through this recorder.
    func database(_ app: Application) -> any Database {
        var logger = Logger(label: "sql-binds") { _ in Handler(recorder: self) }
        logger.logLevel = .debug
        return app.databases.database(logger: logger, on: app.eventLoopGroup.any())!
    }

    fileprivate func record(sql: String, binds: Int) {
        lock.withLock { statements.append((sql, binds)) }
    }

    private struct Handler: LogHandler {
        let recorder: SQLBindRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .debug

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            guard case let .string(sql)? = event.metadata?["sql"], case let .array(binds)? = event.metadata?["binds"] else { return }
            recorder.record(sql: sql, binds: binds.count)
        }
    }
}
