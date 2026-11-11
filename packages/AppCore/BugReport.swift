import Foundation
import Observation

/// What the Mac tells about itself in a bug report, only when the user ticks it: the app's
/// version, the macOS version, the kind of Mac and the language. No names, no serials.
public struct BugReportFacts: Codable, Equatable, Sendable {
    /// "0.2.1". A version the service would refuse ("dev", "1.0-beta") is sent as "0".
    public var appVersion: String
    /// "26.1".
    public var macOS: String
    /// The hardware model identifier, "Mac14,13": a kind of Mac, never one Mac.
    public var model: String
    /// "es": the language only, never the region.
    public var language: String

    public init(appVersion: String, macOS: String, model: String, language: String) {
        self.appVersion = appVersion
        self.macOS = macOS
        self.model = model
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version", macOS = "macos", model, language
    }

    /// This Mac's facts, each reduced to what `services/usage` accepts.
    public static func current(appVersion: String) -> BugReportFacts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"
        return BugReportFacts(
            appVersion: sanitizedVersion(appVersion),
            macOS: macOS,
            model: sanitizedModel(hardwareModel()),
            language: Locale.current.language.languageCode?.identifier ?? "und"
        )
    }

    static func sanitizedVersion(_ version: String) -> String {
        version.wholeMatch(of: /\d{1,4}(\.\d{1,4}){0,3}/) != nil ? version : "0"
    }

    static func sanitizedModel(_ model: String) -> String {
        model.wholeMatch(of: /[A-Za-z]{1,24}(\d{1,3},\d{1,3})?/) != nil ? model : "Mac"
    }

    /// `hw.model` from sysctl: "Mac14,13" on a Mac Studio, the same for every Mac of that kind.
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// One report as it travels to `services/usage` (`POST /v1/reports`). Optional pieces left
/// out are absent from the JSON, not empty.
public struct BugReportPayload: Codable, Equatable, Sendable {
    public var app: String
    public var happened: String
    public var expected: String?
    public var email: String?
    public var log: String?
    public var facts: BugReportFacts?
}

/// The caps the service enforces (`services/usage/src/bug-report.ts`), kept here so the form
/// says so before sending instead of the service refusing.
public enum BugReportLimits {
    /// Characters of "what happened" and of "what was expected".
    public static let text = 4_000
    public static let email = 254
    /// Characters of the attached log; the oldest lines go first. Under the service's 64,000.
    public static let log = 60_000
    /// How far back the attached log reaches.
    public static let logWindow: TimeInterval = 30 * 60
}

/// Where an app's reports go and what it says about itself.
public struct BugReportConfiguration: Sendable {
    /// The app's id in the service's closed list ("batuta", "quill"…).
    public var app: String
    public var appVersion: String
    /// `https://usage.rrios.dev/v1/reports`. It takes no key: nothing can be read back from it.
    public var endpoint: URL
    /// The app's own `os_log` subsystem ("dev.rrios.batuta"): the only lines a log can carry.
    public var logSubsystem: String
    /// Who receives and keeps the reports, as the form's privacy notice names them (GDPR art. 13: the
    /// controller). One constant per app, so each app names its own; a release refuses a placeholder.
    public var privacyController: String
    /// Where a user asks to see or delete their report: an email address or a page.
    public var privacyContact: String

    public init(app: String, appVersion: String, endpoint: URL, logSubsystem: String,
                privacyController: String, privacyContact: String) {
        self.app = app
        self.appVersion = appVersion
        self.endpoint = endpoint
        self.logSubsystem = logSubsystem
        self.privacyController = privacyController
        self.privacyContact = privacyContact
    }

    /// The notice under the form (shared-control S8 fix round, P2): who keeps the report and why, for
    /// how long, how to ask for it or its deletion, and that the user sees what leaves before it does.
    public var privacyNotice: String {
        String(localized: "bugreport.privacy \(privacyController) \(privacyContact)", bundle: .localized)
    }
}

/// A bug report the user writes and sends (shared-control J-28): what happened, what they
/// expected, an email if they want a reply, and two attachments that stay off until ticked —
/// the app's recent log and the Mac's facts. Before anything leaves, the user sees the exact
/// bytes that will be sent (`Phase.reviewing`); `send()` posts those bytes and nothing else.
///
/// A failed send keeps every word, so the user can try again. Nothing is stored on disk.
@MainActor
@Observable
public final class BugReportForm {
    public enum Failure: Equatable, Sendable {
        /// No answer: offline, the server down, a timeout.
        case unreachable
        /// The service refused the report (4xx): the app and the service disagree on the shape.
        case refused
        /// Too many reports reached the service this hour.
        case busy
    }

    public enum Phase: Equatable, Sendable {
        case editing
        /// The exact JSON that `send()` will post.
        case reviewing(preview: String)
        case sending
        case sent
        case failed(Failure)
    }

    /// What stops the review, in the order the form shows them.
    public enum Problem: Equatable, Sendable {
        case nothingHappened
        case happenedTooLong
        case expectedTooLong
        case emailMalformed
    }

    public var happened = ""
    public var expected = ""
    public var email = ""
    /// Off by default (consent, C-50 moment): the log travels only when ticked.
    public var attachLog = false
    /// Off by default: the Mac's facts travel only when ticked.
    public var attachFacts = false

    public private(set) var phase: Phase = .editing

    public let configuration: BugReportConfiguration

    @ObservationIgnored private let log: any RecentLogReading
    @ObservationIgnored private let facts: @Sendable () -> BugReportFacts
    @ObservationIgnored private let send: @Sendable (URLRequest) async throws -> Int
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var body: Data?

    public init(configuration: BugReportConfiguration,
                log: any RecentLogReading = OSLogRecentLog(),
                facts: (@Sendable () -> BugReportFacts)? = nil,
                clock: @escaping @Sendable () -> Date = Date.init,
                send: @escaping @Sendable (URLRequest) async throws -> Int = UsageReport.post) {
        self.configuration = configuration
        self.log = log
        let version = configuration.appVersion
        self.facts = facts ?? { BugReportFacts.current(appVersion: version) }
        self.clock = clock
        self.send = send
    }

    public var problems: [Problem] {
        var found: [Problem] = []
        let happened = happened.trimmingCharacters(in: .whitespacesAndNewlines)
        if happened.isEmpty { found.append(.nothingHappened) }
        if happened.count > BugReportLimits.text { found.append(.happenedTooLong) }
        if expected.trimmingCharacters(in: .whitespacesAndNewlines).count > BugReportLimits.text { found.append(.expectedTooLong) }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty, !Self.isEmail(email) { found.append(.emailMalformed) }
        return found
    }

    public var canReview: Bool { phase == .editing && problems.isEmpty }

    /// What VoiceOver says when the form moves to `phase` (S8 fix round, X4): the review, the sending, the
    /// outcome with its reason. Nil for the fields, where the focus already is.
    public static func announcement(for phase: Phase) -> String? {
        switch phase {
        case .editing: nil
        case .reviewing: String(localized: "bugreport.preview.title", bundle: .localized)
        case .sending: String(localized: "bugreport.sending", bundle: .localized)
        case .sent: String(localized: "bugreport.sent.title", bundle: .localized)
        case .failed(let failure):
            String(localized: "bugreport.failed.title", bundle: .localized) + ". " + BugReportView.failureText(failure)
        }
    }

    /// Builds the report — reading the log now, if ticked — and shows the exact JSON.
    public func review() async {
        guard canReview else { return }
        var log: String?
        if attachLog {
            let since = clock().addingTimeInterval(-BugReportLimits.logWindow)
            let lines = (try? await self.log.lines(subsystem: configuration.logSubsystem, since: since)) ?? []
            log = LogScrub.capped(lines.map(LogScrub.clean), limit: BugReportLimits.log)
        }
        let payload = BugReportPayload(
            app: configuration.app,
            happened: LogScrub.withoutControls(happened.trimmingCharacters(in: .whitespacesAndNewlines)),
            expected: Self.optional(expected).map(LogScrub.withoutControls),
            email: Self.optional(email).map(LogScrub.withoutControls),
            log: log,
            facts: attachFacts ? facts() : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return }
        body = data
        phase = .reviewing(preview: String(decoding: data, as: UTF8.self))
    }

    /// Back to the fields; the next review builds the report again.
    public func edit() {
        guard phase != .sending else { return }
        body = nil
        phase = .editing
    }

    /// Posts the reviewed bytes. Only from the review or after a failure.
    public func submit() async {
        switch phase {
        case .reviewing, .failed: break
        default: return
        }
        guard let body else { return }
        phase = .sending
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let status = try await send(request)
            switch status {
            case 200..<300: phase = .sent
            case 429: phase = .failed(.busy)
            case 400..<500: phase = .failed(.refused)
            default: phase = .failed(.unreachable)
            }
        } catch {
            phase = .failed(.unreachable)
        }
    }

    /// A clean form for the next report, after one was sent.
    public func startOver() {
        guard phase == .sent else { return }
        happened = ""
        expected = ""
        email = ""
        attachLog = false
        attachFacts = false
        body = nil
        phase = .editing
    }

    // MARK: Pieces

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The service's test (`bug-report.ts` EMAIL): something, an @, a domain with a dot.
    static func isEmail(_ text: String) -> Bool {
        text.count <= BugReportLimits.email
            && text.wholeMatch(of: /[^\s@<>()\[\]",;:\\]+@[^\s@<>()\[\]",;:\\]+\.[^\s@<>()\[\]",;:\\]+/) != nil
    }
}

/// What a report's texts and log lines go through before the user sees them. Every text loses
/// the control characters the service refuses; what the user wrote is otherwise theirs. A log
/// line also has the Mac's user — their home folder and their name — replaced, so a line that
/// printed a path does not carry who they are.
public enum LogScrub {
    public static func clean(_ text: String) -> String {
        clean(text, home: NSHomeDirectory(), names: [NSUserName(), NSFullUserName()])
    }

    /// Tab, newline and carriage return stay; every other C0 control and DEL go.
    public static func withoutControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r" || !(scalar.value < 0x20 || scalar.value == 0x7F)
        }))
    }

    static func clean(_ text: String, home: String, names: [String]) -> String {
        var out = withoutControls(text)
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        // Longest first, so a full name goes whole before its first word; whole words only, so a
        // short account name does not eat the middle of an ordinary word.
        for name in names.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "‹user›")
        }
        return out
    }

    /// The newest lines that fit in `limit` characters, oldest first, with a first line that
    /// says how many older ones were left out.
    public static func capped(_ lines: [String], limit: Int) -> String {
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            let cost = line.count + 1
            if size + cost > limit - 64 { break }
            kept.append(line)
            size += cost
        }
        let left = lines.count - kept.count
        let body = kept.reversed().joined(separator: "\n")
        return left > 0 ? "[\(left) older lines left out]\n" + body : body
    }
}
