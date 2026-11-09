import Foundation
import Testing
@testable import AppCore

@MainActor
struct UsageReportTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URLRequest] = []
        var status = 201
        func add(_ request: URLRequest) { lock.withLock { all.append(request) } }
        var requests: [URLRequest] { lock.withLock { all } }
    }

    static let endpoint = UsageReport.Endpoint(url: URL(string: "https://usage.test/v1/usage")!)

    func makeReport(_ sent: Sent = Sent()) -> (UsageReport, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let report = UsageReport(app: "example", version: "1.3.0", allowedCounts: ["rewrites", "meetings"],
                                 endpoint: Self.endpoint, defaults: defaults, calendar: calendar) { request in
            sent.add(request)
            return sent.status
        }
        return (report, defaults)
    }

    static let monday = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00+01:00")!
    static let tuesday = ISO8601DateFormatter().date(from: "2026-10-27T10:00:00+01:00")!

    @Test func nothingIsCountedOrSentBeforeTheUserSaysYes() async {
        let sent = Sent()
        let (report, defaults) = makeReport(sent)
        #expect(report.consent == nil)
        report.count("rewrites", now: Self.monday)
        #expect(await report.flush(now: Self.tuesday) == 0)
        #expect(sent.requests.isEmpty)
        #expect(defaults.data(forKey: "usage.pending") == nil)
    }

    @Test func finishedDaysAreSentOnceAndTodayWaits() async throws {
        let sent = Sent()
        let (report, _) = makeReport(sent)
        report.setConsent(true)
        report.count("rewrites", now: Self.monday)
        report.count("rewrites", now: Self.monday)
        report.count("meetings", now: Self.tuesday)
        report.count("passwords", now: Self.monday)
        #expect(await report.flush(now: Self.tuesday) == 1)
        let body = try JSONSerialization.jsonObject(with: try #require(sent.requests.first?.httpBody)) as? [[String: Any]]
        let day = try #require(body?.first)
        #expect(day["day"] as? String == "2026-10-26")
        #expect(day["app"] as? String == "example")
        #expect((day["counts"] as? [String: Int]) == ["rewrites": 2], "names outside the list are never kept")
        #expect(Set(day.keys) == ["install_id", "app", "day", "version", "macos", "language", "counts"])
        #expect(await report.flush(now: Self.tuesday) == 0, "a sent day is forgotten")
        #expect(report.preview(now: Self.tuesday.addingTimeInterval(86_400)).map(\.day) == ["2026-10-27"])
    }

    @Test func aFailedSendKeepsTheDays() async {
        let sent = Sent()
        sent.status = 500
        let (report, _) = makeReport(sent)
        report.setConsent(true)
        report.count("rewrites", now: Self.monday)
        #expect(await report.flush(now: Self.tuesday) == 0)
        #expect(report.preview(now: Self.tuesday).count == 1)
    }

    @Test func sayingNoForgetsEverything() {
        let (report, defaults) = makeReport()
        report.setConsent(true)
        let id = defaults.string(forKey: "usage.installID")
        #expect(id != nil)
        report.count("rewrites", now: Self.monday)
        report.setConsent(false)
        #expect(defaults.string(forKey: "usage.installID") == nil)
        #expect(defaults.data(forKey: "usage.pending") == nil)
        report.setConsent(true)
        #expect(defaults.string(forKey: "usage.installID") != id, "a new yes is a new id")
    }

    @Test func theAnswerSurvivesARelaunch() {
        let (report, defaults) = makeReport()
        report.setConsent(false)
        let again = UsageReport(app: "example", version: "1.3.0", allowedCounts: [], endpoint: Self.endpoint, defaults: defaults)
        #expect(again.consent == false)
    }

    @Test func aMacOfflineForWeeksKeepsTwoWeeksAtMost() {
        let (report, _) = makeReport()
        report.setConsent(true)
        for offset in 0..<30 { report.count("rewrites", now: Self.monday.addingTimeInterval(Double(offset) * 86_400)) }
        #expect(report.preview(now: Self.monday.addingTimeInterval(40 * 86_400)).count == UsageReport.maximumPendingDays)
    }
}
