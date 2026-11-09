import Foundation
import Observation

/// One day of an app's use on one Mac, as it is sent: counts, never content.
public struct UsageDay: Codable, Equatable, Sendable {
    /// Random, made when the user said yes and forgotten when they say no: lets days of
    /// the same Mac be counted as one person, and nothing else.
    public var installID: UUID
    public var app: String
    /// "2026-10-30", in the Mac's calendar.
    public var day: String
    public var version: String
    /// "27": the major version only.
    public var macOS: String
    /// "es": the language only, never the region.
    public var language: String
    /// Feature name → times used that day ("rewrites": 4). Names come from the app's
    /// closed list (`UsageReport.allowedCounts`).
    public var counts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case installID = "install_id", app, day, version
        case macOS = "macos", language, counts
    }
}

/// Usage statistics an app sends only with the user's prior consent.
///
/// Off until the user says yes: asked once, a switch in Settings. Asking is the law here,
/// not a courtesy: reading anything from someone's Mac to send it needs prior consent
/// in the EU (LSSI art. 22.2, ePrivacy art. 5(3); EDPB Guidelines 2/2023 bring apps and
/// telemetry under it). Without consent nothing is counted, so nothing can leak later.
///
/// What is kept is a count per feature per day, in the app's defaults; finished days are
/// sent once a day and forgotten when the server accepts them. Saying no deletes the
/// pending days and the install id at once.
@MainActor
@Observable
public final class UsageReport {
    /// Where finished days go: an insert-only endpoint (`services/usage`, `POST /v1/usage`).
    /// It takes no key: there is nothing to read back from it.
    public struct Endpoint: Sendable {
        public var url: URL

        public init(url: URL) {
            self.url = url
        }
    }

    public let app: String
    public let version: String
    public let allowedCounts: Set<String>

    @ObservationIgnored private let endpoint: Endpoint
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let send: @Sendable (URLRequest) async throws -> Int
    @ObservationIgnored private let calendar: Calendar

    private var consentKey: String { "usage.consent" }
    private var installKey: String { "usage.installID" }
    private var pendingKey: String { "usage.pending" }

    /// Days kept unsent at most: a Mac offline for weeks does not pile them up.
    public static let maximumPendingDays = 14

    public init(app: String, version: String, allowedCounts: Set<String>, endpoint: Endpoint,
                defaults: UserDefaults = .standard, calendar: Calendar = .current,
                send: @escaping @Sendable (URLRequest) async throws -> Int = UsageReport.post) {
        self.app = app
        self.version = version
        self.allowedCounts = allowedCounts
        self.endpoint = endpoint
        self.defaults = defaults
        self.calendar = calendar
        self.send = send
        consent = defaults.object(forKey: "usage.consent") as? Bool
    }

    /// nil: never asked. The app asks once, then the switch in Settings changes it.
    public private(set) var consent: Bool?

    public var isEnabled: Bool { consent == true }

    /// The user's answer. No deletes everything kept so far.
    public func setConsent(_ allowed: Bool) {
        consent = allowed
        defaults.set(allowed, forKey: consentKey)
        if allowed {
            if defaults.string(forKey: installKey) == nil { defaults.set(UUID().uuidString, forKey: installKey) }
        } else {
            defaults.removeObject(forKey: installKey)
            defaults.removeObject(forKey: pendingKey)
        }
    }

    /// Counts one use of `feature` today. Does nothing without consent or for a name
    /// outside the app's list.
    public func count(_ feature: String, by amount: Int = 1, now: Date = Date()) {
        guard isEnabled, allowedCounts.contains(feature), amount > 0 else { return }
        var pending = self.pending
        let day = Self.dayString(now, calendar: calendar)
        pending[day, default: [:]][feature, default: 0] += amount
        let kept = pending.keys.sorted().suffix(Self.maximumPendingDays)
        save(pending.filter { kept.contains($0.key) })
    }

    /// Exactly what would be sent now: the finished days, shown in Settings.
    public func preview(now: Date = Date()) -> [UsageDay] {
        guard isEnabled, let id = defaults.string(forKey: installKey).flatMap(UUID.init(uuidString:)) else { return [] }
        let today = Self.dayString(now, calendar: calendar)
        return pending.keys.sorted().filter { $0 < today }.map { day in
            UsageDay(installID: id, app: app, day: day, version: version, macOS: Self.macOSMajor,
                     language: Self.language, counts: pending[day] ?? [:])
        }
    }

    /// Sends the finished days; each accepted one is forgotten. A failure keeps them for
    /// the next try. Returns how many were sent.
    @discardableResult
    public func flush(now: Date = Date()) async -> Int {
        let days = preview(now: now)
        guard !days.isEmpty else { return 0 }
        var request = URLRequest(url: endpoint.url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(days) else { return 0 }
        request.httpBody = body
        // A day the server already has is ignored there, so a retry after a lost answer
        // never counts twice.
        guard let status = try? await send(request), (200..<300).contains(status) else { return 0 }
        var pending = self.pending
        for day in days { pending[day.day] = nil }
        save(pending)
        return days.count
    }

    // MARK: Pieces

    private var pending: [String: [String: Int]] {
        guard let data = defaults.data(forKey: pendingKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: Int]].self, from: data)) ?? [:]
    }

    private func save(_ pending: [String: [String: Int]]) {
        defaults.set(try? JSONEncoder().encode(pending), forKey: pendingKey)
    }

    nonisolated static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    nonisolated static var macOSMajor: String { String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    nonisolated static var language: String { Locale.current.language.languageCode?.identifier ?? "und" }

    public nonisolated static func post(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
