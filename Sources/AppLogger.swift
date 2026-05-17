import OSLog

/// Unified logging facade. Replaces `print()` with structured `os_log` output.
///
/// Debug-level logs are stripped in Release builds to avoid console noise.
/// Info-level logs are always emitted for operational visibility.
struct AppLogger {

    static let shared = Logger(subsystem: "com.focustrafficlight.app", category: "FocusRecovery")

    /// Debug logs — stripped in Release builds.
    static func debug(_ message: String) {
        #if DEBUG
        shared.debug("\(message, privacy: .public)")
        #endif
    }

    /// Info logs — always emitted (startup, focus changes, errors).
    static func info(_ message: String) {
        shared.info("\(message, privacy: .public)")
    }
}
