import Foundation

/// Default `Log` that prints to the console, tagged by label and category.
///
/// `isEnabled` gates output at runtime (e.g. wired to a debug toggle); when it
/// returns `false`, writing is a no-op.
public struct ConsoleLog: Log {
    /// Prefix printed before every message, usually the app or subsystem name.
    public let label: String

    /// Runtime gate that decides whether this logger writes messages.
    public let isEnabled: @Sendable () -> Bool

    public init(
        label: String,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.label = label
        self.isEnabled = isEnabled
    }

    public func write(_ message: String, level: LogLevel, category: String) {
        guard isEnabled() else { return }
        let tag = category.isEmpty ? level.rawValue.uppercased() : category
        print("[\(label)][\(tag)] \(message)")
    }
}
