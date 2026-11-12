import Foundation

/// Severity of a log message.
public enum LogLevel: String, Sendable {
    /// Detailed information useful during development.
    case debug

    /// General information about normal runtime behavior.
    case info

    /// Information about recoverable or unexpected behavior.
    case warning

    /// Information about failures that need attention.
    case error
}
