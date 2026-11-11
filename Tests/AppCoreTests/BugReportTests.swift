import Foundation
import Testing
@testable import AppCore

@MainActor
struct BugReportTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URLRequest] = []
        private var next: Result<Int, URLError> = .success(201)
        func add(_ request: URLRequest) { lock.withLock { all.append(request) } }
        var requests: [URLRequest] { lock.withLock { all } }
        var answer: Result<Int, URLError> {
            get { lock.withLock { next } }
            set { lock.withLock { next = newValue } }
        }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (String, Date)?
        func set(_ subsystem: String, _ since: Date) { lock.withLock { value = (subsystem, since) } }
        var last: (String, Date)? { lock.withLock { value } }
    }

    struct FakeLog: RecentLogReading {
        var lines: [String]
        let asked = Asked()
        func lines(subsystem: String, since: Date) async throws -> [String] {
            asked.set(subsystem, since)
            return lines
        }
    }

    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
    nonisolated static let configuration = BugReportConfiguration(
        app: "batuta", appVersion: "0.2.1",
        endpoint: URL(string: "https://usage.test/v1/reports")!, logSubsystem: "dev.rrios.batuta",
        privacyController: "Ana Test (example.org)", privacyContact: "privacy@example.org")
    nonisolated static let facts = BugReportFacts(appVersion: "0.2.1", macOS: "26.1", model: "Mac14,13", language: "es")

    func makeForm(_ sent: Sent = Sent(), log: FakeLog = FakeLog(lines: ["12:00:01.000 info engine: started"])) -> BugReportForm {
        BugReportForm(configuration: Self.configuration, log: log, facts: { Self.facts }, clock: { Self.now }) { request in
            sent.add(request)
            return try sent.answer.get()
        }
    }

    func preview(_ form: BugReportForm) -> String? {
        if case .reviewing(let text) = form.phase { return text }
        return nil
    }

    func json(_ text: String?) throws -> [String: Any] {
        let data = try #require(text?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func attachmentsAreOffAndOnlyTheTextTravelsByDefault() async throws {
        let log = FakeLog(lines: ["secret line"])
        let form = makeForm(log: log)
        #expect(form.attachLog == false)
        #expect(form.attachFacts == false)
        form.happened = "  The pointer stays on the Mac.  "
        await form.review()
        let body = try json(preview(form))
        #expect(Set(body.keys) == ["app", "happened"])
        #expect(body["happened"] as? String == "The pointer stays on the Mac.")
        #expect(log.asked.last == nil, "the log is not even read when it is not ticked")
    }

    @Test func tickedPiecesTravelAndNothingElse() async throws {
        let log = FakeLog(lines: ["12:00:01.000 info engine: started"])
        let form = makeForm(log: log)
        form.happened = "It does not cross."
        form.expected = "That it crosses."
        form.email = "ana@example.com"
        form.attachLog = true
        form.attachFacts = true
        await form.review()
        let body = try json(preview(form))
        #expect(Set(body.keys) == ["app", "happened", "expected", "email", "log", "facts"])
        #expect(body["log"] as? String == "12:00:01.000 info engine: started")
        let facts = try #require(body["facts"] as? [String: String])
        #expect(facts == ["app_version": "0.2.1", "macos": "26.1", "model": "Mac14,13", "language": "es"])
        let asked = try #require(log.asked.last)
        #expect(asked.0 == "dev.rrios.batuta")
        #expect(asked.1 == Self.now.addingTimeInterval(-30 * 60))
    }

    @Test func whatIsSentIsExactlyWhatWasShown() async throws {
        let sent = Sent()
        let form = makeForm(sent)
        form.happened = "It does not cross."
        form.attachFacts = true
        await form.review()
        let shown = try #require(preview(form))
        await form.submit()
        #expect(form.phase == .sent)
        let request = try #require(sent.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.configuration.endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(shown.utf8))
    }

    @Test func reviewWaitsForTextAndAWellFormedEmail() async {
        let form = makeForm()
        #expect(form.problems == [.nothingHappened])
        #expect(form.canReview == false)
        await form.review()
        #expect(form.phase == .editing)
        form.happened = "Something"
        form.email = "ana at example"
        #expect(form.problems == [.emailMalformed])
        form.email = "ana@example.com"
        #expect(form.canReview)
        form.happened = String(repeating: "a", count: BugReportLimits.text + 1)
        form.expected = String(repeating: "b", count: BugReportLimits.text + 1)
        #expect(form.problems == [.happenedTooLong, .expectedTooLong])
    }

    @Test func aFailureKeepsEveryWordAndRetrySendsTheSameBytes() async throws {
        let sent = Sent()
        sent.answer = .failure(URLError(.notConnectedToInternet))
        let form = makeForm(sent)
        form.happened = "It does not cross."
        form.email = "ana@example.com"
        await form.review()
        await form.submit()
        #expect(form.phase == .failed(.unreachable))
        #expect(form.happened == "It does not cross.")
        #expect(form.email == "ana@example.com")
        sent.answer = .success(201)
        await form.submit()
        #expect(form.phase == .sent)
        #expect(sent.requests.count == 2)
        #expect(sent.requests[0].httpBody == sent.requests[1].httpBody)
    }

    @Test(arguments: [(429, BugReportForm.Failure.busy), (422, .refused), (413, .refused), (502, .unreachable)])
    func theServiceAnswerIsNamed(status: Int, failure: BugReportForm.Failure) async {
        let sent = Sent()
        sent.answer = .success(status)
        let form = makeForm(sent)
        form.happened = "It does not cross."
        await form.review()
        await form.submit()
        #expect(form.phase == .failed(failure))
    }

    @Test func nothingIsSentWithoutAReview() async {
        let sent = Sent()
        let form = makeForm(sent)
        form.happened = "It does not cross."
        await form.submit()
        #expect(sent.requests.isEmpty)
        await form.review()
        form.edit()
        await form.submit()
        #expect(sent.requests.isEmpty, "going back to edit forgets the reviewed bytes")
    }

    @Test func startingOverClearsTheFormAndTheTicks() async {
        let form = makeForm()
        form.happened = "It does not cross."
        form.attachLog = true
        await form.review()
        await form.submit()
        form.startOver()
        #expect(form.phase == .editing)
        #expect(form.happened.isEmpty)
        #expect(form.attachLog == false)
    }

    @Test func controlCharactersNeverReachTheService() async throws {
        let form = makeForm()
        form.happened = "a\u{0}b\u{1B}[31mc\nd"
        await form.review()
        #expect(try json(preview(form))["happened"] as? String == "ab[31mc\nd")
    }

    @Test func logLinesLoseTheUsersHomeAndName() {
        let line = LogScrub.clean("opened /Users/ana/Library/x for Ana Garcia (ana)",
                                  home: "/Users/ana", names: ["ana", "Ana Garcia"])
        #expect(line == "opened ~/Library/x for ‹user› (‹user›)")
        #expect(LogScrub.clean("a banana", home: "/Users/ana", names: ["ana"]) == "a banana")
    }

    @Test func aLongLogKeepsTheNewestLinesAndSaysHowManyWent() {
        let lines = (1...100).map { String(format: "line %03d", $0) }
        let capped = LogScrub.capped(lines, limit: 64 + 9 * 10)
        let kept = capped.split(separator: "\n")
        #expect(kept.first == "[90 older lines left out]")
        #expect(kept.last == "line 100")
        #expect(kept.count == 11)
        #expect(LogScrub.capped(["a", "b"], limit: 1_000) == "a\nb")
    }

    @Test func factsAreReducedToWhatTheServiceAccepts() {
        #expect(BugReportFacts.sanitizedVersion("0.2.1") == "0.2.1")
        #expect(BugReportFacts.sanitizedVersion("1.0-beta") == "0")
        #expect(BugReportFacts.sanitizedModel("Mac14,13") == "Mac14,13")
        #expect(BugReportFacts.sanitizedModel("Ana's MacBook") == "Mac")
        let here = BugReportFacts.current(appVersion: "dev")
        #expect(here.appVersion == "0")
        #expect(here.macOS.wholeMatch(of: /\d{1,3}(\.\d{1,3}){1,2}/) != nil)
        #expect(here.model.wholeMatch(of: /[A-Za-z]{1,24}(\d{1,3},\d{1,3})?/) != nil)
    }

    // S8 fix round, P2: GDPR art. 13 for a form that takes an email and free text — who keeps it, why,
    // for how long, and where to ask for it or its deletion — with each app's own controller and contact.
    @Test func thePrivacyNoticeNamesTheControllerTheContactAndTheYear() throws {
        let notice = Self.configuration.privacyNotice
        #expect(notice.contains("Ana Test (example.org)"))
        #expect(notice.contains("privacy@example.org"))
        #expect(notice != "bugreport.privacy %@ %@")
        // Every one of AppCore's ten languages has the notice with both values in it.
        for language in ["de", "en", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-Hans"] {
            let path = try #require(Bundle.localized.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                         forLocalization: language))
            let table = NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
            let pattern = try #require(table["bugreport.privacy %@ %@"], "\(language) has no privacy notice")
            #expect(pattern.contains("%1$@") && pattern.contains("%2$@"), "\(language) names neither value")
            #expect(table["bugreport.privacy"] == nil, "\(language) keeps the old notice")
        }
    }

    // S8 fix round, X4: each step after the fields is said out loud, the failure with its reason.
    @Test func everyStepAfterTheFieldsIsAnnounced() {
        #expect(BugReportForm.announcement(for: .editing) == nil)
        let steps: [BugReportForm.Phase] = [.reviewing(preview: "{}"), .sending, .sent, .failed(.busy), .failed(.unreachable)]
        let said = steps.map { BugReportForm.announcement(for: $0) ?? "" }
        #expect(said.allSatisfy { !$0.isEmpty && !$0.hasPrefix("bugreport.") })
        #expect(Set(said).count == said.count)
        #expect(said[3].contains(BugReportView.failureText(.busy)))
    }
}
