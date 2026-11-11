import Foundation
import OSLog

/// Reads an app's own recent log lines, for a bug report the user chose to attach it to.
public protocol RecentLogReading: Sendable {
    /// The lines of `subsystem` since `since`, oldest first, already formatted.
    func lines(subsystem: String, since: Date) async throws -> [String]
}

/// The app's own unified-log entries, read with `OSLogStore` scoped to the current process:
/// no entitlement, no other app's lines, nothing from before this launch.
///
/// Values the app logged as private (every dynamic string, unless marked public) come back
/// as the system redacted them; nothing here can bring them back, and
/// `RecentLogTests.privateValuesStayRedacted` checks it on this Mac's own store.
/// Docs: https://developer.apple.com/documentation/oslog/oslogstore
/// Docs: https://developer.apple.com/documentation/os/generating-log-messages-from-your-code
public struct OSLogRecentLog: RecentLogReading {
    public init() {}

    public func lines(subsystem: String, since: Date) async throws -> [String] {
        // OSLogStore reads synchronously and can take a moment over half an hour of entries.
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(
                at: store.position(date: since),
                matching: NSPredicate(format: "subsystem == %@", subsystem)
            )
            let time = Date.FormatStyle()
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                .secondFraction(.fractional(3))
            return entries.compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog, log.date >= since else { return nil }
                return "\(log.date.formatted(time)) \(Self.level(log.level)) \(log.category): \(log.composedMessage)"
            }
        }.value
    }

    static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }
}
