import OSLog

/// Unified logging facade. Replaces `print()` with structured `os_log` output.
///
/// Debug-level logs are stripped in Release builds to avoid console noise.
/// Notice-level logs are persisted to disk, which is what makes a failure
/// diagnosable after the fact: `Logger.info` is memory-only and the ring buffer
/// only holds a few minutes, so `log show` could not see the old pipeline at all.
struct AppLogger {

    static let shared = Logger(subsystem: "com.focustrafficlight.app", category: "FocusRecovery")

    /// Debug logs — stripped in Release builds.
    static func debug(_ message: String) {
        #if DEBUG
        shared.debug("\(message, privacy: .public)")
        #endif
    }

    /// Info logs — always emitted, but memory-only.
    static func info(_ message: String) {
        shared.info("\(message, privacy: .public)")
    }

    /// Notice logs — persisted to disk. Used for the decision points of the
    /// focus pipeline (triggers, skips, activation results) so they survive long
    /// enough to be read back with `log show`.
    static func notice(_ message: String) {
        shared.notice("\(message, privacy: .public)")
    }
}
