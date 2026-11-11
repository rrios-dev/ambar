import Foundation
import OSLog
import Testing
@testable import AppCore

/// The live reader against this process's own unified log: what a report would attach.
struct RecentLogTests {
    @Test func readsOnlyItsSubsystemAndPrivateValuesStayRedacted() async throws {
        let subsystem = "dev.rrios.appcore.tests.\(UUID().uuidString)"
        let logger = Logger(subsystem: subsystem, category: "report")
        let other = Logger(subsystem: "dev.rrios.appcore.tests.other", category: "report")
        let since = Date().addingTimeInterval(-1)
        let secret = "secret-\(UUID().uuidString)"
        let visible = "visible-\(UUID().uuidString)"
        logger.notice("public \(visible, privacy: .public)")
        logger.notice("private \(secret, privacy: .private)")
        logger.notice("default \(secret)")
        other.notice("other \(visible, privacy: .public)")

        let lines = try await OSLogRecentLog().lines(subsystem: subsystem, since: since)
        let all = lines.joined(separator: "\n")
        #expect(lines.count == 3)
        #expect(all.contains("public \(visible)"))
        #expect(!all.contains("other "))
        #expect(!all.contains(secret), "a private value must not come back readable")
        #expect(lines.allSatisfy { $0.contains(" notice report: ") })
    }
}
