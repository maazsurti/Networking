import Foundation

/// A logging sink: conformers decide how and where a message is written.
///
/// This module knows nothing about any consumer. An app picks a `Log`
/// implementation and feeds it wherever logging is needed (including into a
/// library's own logger seam), so libraries never depend on `Diagnostics`.
public protocol Log: Sendable {
    func write(_ message: String, level: LogLevel, category: String)
}

public extension Log {
    /// Ergonomic call site — `log("message")`, with level and category optional.
    func callAsFunction(
        _ message: String,
        level: LogLevel = .debug,
        category: String = ""
    ) {
        write(message, level: level, category: category)
    }
}
